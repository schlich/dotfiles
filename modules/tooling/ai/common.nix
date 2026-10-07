{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  iwe = import ../knowledge/iwe-package.nix { inherit inputs lib pkgs; };
  kbRoot = "${config.home.homeDirectory}/kb";
  # iwec serves the workspace in its working directory.
  kbMcp = pkgs.writeNuScriptBin "kb-mcp" ''
    def main [] {
      if not ("${kbRoot}/.iwe" | path exists) {
        print --stderr "kb-mcp: no IWE workspace at ${kbRoot}; run `iwe init` there first"
        exit 1
      }
      cd ${kbRoot}
      exec ${iwe}/bin/iwec --transport stdio
    }
  '';
  # Runs the target workspace's own jj/ci.nu, so it needs what the `ci`
  # wrapper in modules/programs/vcs.nix provides. The ruff flake check lints
  # the source; writers.writePython3 would run flake8 instead.
  ciMcp =
    pkgs.runCommand "ci-mcp"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta.mainProgram = "ci-mcp";
      }
      ''
        makeWrapper ${pkgs.python3.withPackages (ps: [ ps.mcp ])}/bin/python "$out/bin/ci-mcp" \
          --add-flags ${../../../jj/mcp.py} \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.git
              pkgs.gh
            ]
          } \
          --set CI_MCP_NU ${lib.getExe config.programs.nushell.package}
      '';
in
{
  programs.mcp = {
    enable = true;
    servers = {
      chrome-devtools = {
        command = "npx";
        args = [
          "-y"
          "chrome-devtools-mcp@latest"
        ];
      };
      jj = {
        command = "npx";
        args = [
          "-y"
          "jj-mcp@1.0.8"
        ];
      };
      nix = {
        command = "uvx";
        args = [ "mcp-nixos" ];
      };
      nushell = {
        # Pin a Nushell by store path: environments such as dev shells can put
        # an older nu first on PATH, which rejects commands config.nu relies on.
        command = lib.getExe (pkgs.callPackage ./nushell-mcp.nix { });
        # The output limit and the `job-log` command for background jobs.
        args = [
          "--config"
          "${./scripts/nu-mcp-config.nu}"
          "--mcp"
        ];
      };
      atuin = {
        command = "atuin";
        args = [ "mcp" ];
      };
      # The personal knowledge base, for agents working in other repositories.
      kb.command = "${kbMcp}/bin/kb-mcp";
      # The `ci` trunk workflow as tools, in the client's working directory.
      ci.command = "${ciMcp}/bin/ci-mcp";
    }
    // lib.optionalAttrs pkgs.stdenv.hostPlatform.isDarwin {
      # metavr ships binaries only for macOS and Windows, not Linux.
      metavr = {
        command = "npx";
        args = [
          "-y"
          "metavr"
          "mcp"
          "server"
        ];
      };
    };
  };
}
