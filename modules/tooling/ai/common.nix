{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  iwe = import ../knowledge/iwe-package.nix { inherit inputs lib pkgs; };
  atuin = import ../../programs/atuin-package.nix { inherit inputs pkgs; };
  kbRoot = "${config.home.homeDirectory}/kb";
  xs = inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default;
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
  # The ci input's MCP server, which starts the same `ci` as the shell; with
  # xs it announces its jobs on cross.stream.
  ciMcp = inputs.ci.packages.${pkgs.stdenv.hostPlatform.system}.ci-mcp.override {
    inherit xs;
    ci = config.dotfiles.ci.package;
  };
  sudoplz = pkgs.callPackage ./sudoplz.nix { };
  # Hides the 2026-07-28 MCP handshake from servers that claim it but
  # answer tools/list without its required fields (atuin 18.21 and 18.23).
  mcpLegacyHandshake = pkgs.writers.writePython3Bin "mcp-legacy-handshake" { } (
    builtins.readFile ./scripts/mcp-legacy-handshake.py
  );
in
{
  imports = [ ../../programs/ci.nix ];

  home.packages = [
    # The jj, nix and chrome-devtools servers start through npx and uvx.
    pkgs.nodejs
    pkgs.uv
    # Monitor command for a Nushell job's log and done marker, so the
    # Monitor card shows one titled line instead of an inline poll loop.
    (pkgs.writeNuScriptBin "watch-job" (builtins.readFile ./scripts/watch-job.nu))
    sudoplz
  ];
  # Agents run `sudo -A`, which asks sudoplz's askpass; it shows the command
  # in a dialog and supplies the stored password only when approved.
  home.sessionVariables.SUDO_ASKPASS = "${sudoplz}/bin/askpass";

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
        command = "nix";
        args = [
          "run"
          "github:utensils/mcp-nixos"
          "--"
        ];
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
      # Remove the wrapper once tests/atuin-mcp.nu finds that atuin answers
      # the 2026-07-28 tools/list with ttlMs and cacheScope.
      atuin = {
        command = lib.getExe mcpLegacyHandshake;
        args = [
          "atuin"
          "mcp"
        ];
      };
      # The personal knowledge base, for agents working in other repositories.
      kb.command = "${kbMcp}/bin/kb-mcp";
      # The `ci` trunk workflow as tools, in the client's working directory.
      ci.command = "${ciMcp}/bin/ci-mcp";
      # Stately's hosted HTTP MCP server provides access to state-machine
      # design tools; authentication is handled by the MCP client.
      stately.url = "https://mcp.stately.ai/mcp";
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

  # Follow `job-log` and ci MCP jobs as a Monitor running watch-job does,
  # with a local cross.stream store and without one.
  dotfiles.tooling.checks.watch-job =
    pkgs.runCommand "watch-job-check"
      {
        nativeBuildInputs = [
          pkgs.nushell
          xs
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        nu --config ${./scripts/nu-mcp-config.nu} ${./tests/watch-job.nu} ${./scripts/watch-job.nu}
        touch "$out"
      '';

  # Claude Code's 2026-07-28 handshake reaches atuin's tools through
  # mcp-legacy-handshake.
  dotfiles.tooling.checks.atuin-mcp =
    pkgs.runCommand "atuin-mcp-check"
      {
        nativeBuildInputs = [
          pkgs.nushell
          pkgs.coreutils
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        nu ${./tests/atuin-mcp.nu} ${lib.getExe mcpLegacyHandshake} ${lib.getExe atuin}
        touch "$out"
      '';
}
