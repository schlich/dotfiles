{
  config,
  lib,
  pkgs,
  ...
}:

# `notebook`: marimo notebooks that keep running in Rex terminals, on this
# machine or on a Rex host, opened in this machine's browser (notebook.nu);
# and `notebook-serve`, which starts marimo in the project's Python
# environment on the host that holds the files (notebook-serve.nu). Every
# home with Rex gets both, so a workstation serves its own notebooks and opens
# a server's: dotfiles.rex.hosts names the hosts it reaches, at the same
# tailnet addresses as `rex -S`. A host's marimo stays on that host's
# loopback, and reaches this machine through `rex forward open`.
let
  rex = lib.getExe config.programs.rex.package;

  # notebook-serve around a marimo: nixpkgs' here, a stand-in in the check.
  serveWith =
    marimo:
    pkgs.writeNuScriptBin "notebook-serve" (
      lib.replaceStrings [ "@marimo@" ] [ marimo ] (builtins.readFile ./notebook-serve.nu)
    );
  serve = serveWith (lib.getExe pkgs.marimo);

  notebookConfig = (pkgs.formats.json { }).generate "notebook.json" {
    inherit rex;
    session = "notebooks";
    inherit (config.dotfiles.rex) hosts;
    serve = "${serve}/bin/notebook-serve";
    setsid = lib.getExe' pkgs.util-linux "setsid";
  };
  notebook = pkgs.writeText "notebook.nu" ''
    $env.NOTEBOOK_CONFIG = "${notebookConfig}"
    ${builtins.readFile ./notebook.nu}
  '';

  # Stands in for marimo in the check: serves the target's folder on a free
  # loopback port and prints marimo's URL line.
  marimoStandIn = pkgs.writeScript "marimo-stand-in" ''
    #!${pkgs.python3.interpreter}
    import http.server, os, secrets, sys

    target = sys.argv[-1]
    os.chdir(target if os.path.isdir(target) else os.path.dirname(target))


    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass


    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
    port = server.server_address[1]
    print(f"URL: http://localhost:{port}?access_token={secrets.token_urlsafe(8)}", flush=True)
    server.serve_forever()
  '';
in
{
  home.packages = [ serve ];
  dotfiles.nushellAutoload.notebook = notebook;

  # The commands against two private Rex servers, one of them standing in for
  # a Rex host, with the stand-in marimo.
  dotfiles.tooling.checks.rex-notebooks =
    pkgs.runCommand "rex-notebooks-check"
      {
        nativeBuildInputs = [
          pkgs.nushell
          config.programs.rex.package
          (serveWith "${marimoStandIn}")
        ];
      }
      ''
        export HOME="$TMPDIR/home" SHELL=${pkgs.runtimeShell}
        mkdir -p "$HOME"
        cat ${./notebook.nu} ${./test.nu} > check.nu
        nu check.nu
        touch "$out"
      '';
}
