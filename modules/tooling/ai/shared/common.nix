{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  inherit (pkgs) iwe;
  inherit (pkgs) atuin;
  kbRoot = config.dotfiles.paths.kb;
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
  # The `honeycomb` command's package, which also ships `honeycomb-mcp`.
  inherit (inputs.honeycomb.overlays.default pkgs pkgs) honeycomb;
  sudoplz = pkgs.callPackage ./sudoplz.nix { };
  # Hides the 2026-07-28 MCP handshake from servers that claim it but
  # answer tools/list without its required fields (atuin 18.21 and 18.23).
  mcpLegacyHandshake = pkgs.writers.writePython3Bin "mcp-legacy-handshake" { } (
    builtins.readFile ../scripts/mcp-legacy-handshake.py
  );
in
{
  imports = [ ../../../programs/vcs/ci.nix ];

  dotfiles.nixpkgsWatch = {
    sudoplz = {
      inherit (sudoplz) version;
      repo = "crypdick/sudoplz";
      reason = "replace modules/tooling/ai/shared/sudoplz.nix, a build of upstream's main, with pkgs.sudoplz in modules/tooling/ai/shared/common.nix";
    };
    jj-mcp = {
      inherit (pkgs.callPackage ../mcp/jj-mcp { }) version;
      reason = "replace modules/tooling/ai/mcp/jj-mcp, a build of the npm release, with pkgs.jj-mcp in modules/tooling/ai/shared/common.nix";
    };
  };

  home.packages = [
    # Copilot's and OpenCode's chrome-devtools server starts through npx.
    pkgs.nodejs
    pkgs.uv
    # Monitor command for a Nushell job's log and done marker, so the
    # Monitor card shows one titled line instead of an inline poll loop.
    (pkgs.writeNuScriptBin "watch-job" (builtins.readFile ../scripts/watch-job.nu))
    sudoplz
  ];
  # This repository runs on luvus's Git worktrees and merge gate; ci stays for
  # the others.
  dotfiles.tooling.gitWorkflowRepos = [ config.dotfiles.paths.dotfiles ];

  # Agents run `sudo -A`, which asks sudoplz's askpass; it shows the command
  # in a dialog and supplies the stored password only when approved.
  home.sessionVariables.SUDO_ASKPASS = "${sudoplz}/bin/askpass";

  # `mcp probe http|stdio` checks a server's handshake and tool list; `secret
  # with` hands it a SecretSpec key without the key reaching any output.
  dotfiles.nushellAutoload = {
    mcp = ../scripts/mcp.nu;
    secret = ../scripts/secret.nu;
  };

  programs.mcp = {
    enable = true;
    servers = {
      # Built ahead of time, so sessions start no `npm exec` parent for it.
      jj.command = lib.getExe (pkgs.callPackage ../mcp/jj-mcp { });
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
        command = lib.getExe pkgs.nushell;
        # The output limit and the `job-log` command for background jobs.
        args = [
          "--config"
          "${../scripts/nu-mcp-config.nu}"
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
      # The six-at-a-time counts (census, prune, sessions, sidebar, flower)
      # as tools, so an agent checks them before starting another topic
      # (github:schlich/honeycomb). Only `prune` with `yes` changes anything.
      honeycomb.command = lib.getExe' honeycomb "honeycomb-mcp";
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

  # Antigravity / Gemini CLI configuration: shares the MCP servers (including
  # `kb`), global instructions, and skills. T3 Code also symlinks
  # `~/.gemini/antigravity-cli/skills` into its isolated Antigravity profiles.
  programs.antigravity-cli = {
    enable = true;
    mutableSettings = true;
    enableMcpIntegration = true;
    context.GEMINI = ./global-agent-instructions.md;
    skills = (import ./shared-skills.nix { inherit inputs; }) // {
      kb = ''
        ---
        name: kb
        description: Search or update the user's personal IWE knowledge base (kb MCP / ~/Research/kb) for cross-project facts, traps, rules, and decisions.
        ---

        # Personal Knowledge Base

        The user's durable personal knowledge base is an IWE workspace at `~/Research/kb`, exposed through the `kb` MCP server (`iwe_find`, `iwe_retrieve`, `iwe_tree`, and writes).

        - Search it with `iwe_find` before re-deriving a cross-project fact or asking the user something they may already have recorded.
        - Write to it only with the user's explicit approval. Offer a one-line `"Worth remembering: <title>"` instead of writing unasked.
        - After an approved write, run `kb sync` so the change commits and pushes to the private remote immediately (a background timer also syncs settled edits automatically).
        - Treat its contents as private: never copy them into a public repository, issue, or pull request without approval.
      '';
    };
  };

  # Follow `job-log` jobs (and earlier ci MCP jobs' records) as a Monitor
  # running watch-job does,
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
        nu --config ${../scripts/nu-mcp-config.nu} ${../tests/watch-job.nu} ${../scripts/watch-job.nu}
        touch "$out"
      '';

  # `job-log --rex` against a Rex server of the check's own: a passing and a
  # failing job, the log and status watch-job reads, and the kept terminal.
  dotfiles.tooling.checks.job-log-rex =
    pkgs.runCommand "job-log-rex-check"
      {
        nativeBuildInputs = [
          pkgs.nushell
          inputs.rex.packages.${pkgs.stdenv.hostPlatform.system}.rex
        ];
      }
      ''
        export HOME="$TMPDIR/home" SHELL=${pkgs.runtimeShell}
        mkdir -p "$HOME"
        nu --config ${../scripts/nu-mcp-config.nu} ${../tests/job-log-rex.nu}
        touch "$out"
      '';

  # `mcp probe` against a stdio server, and `secret with` against a stub
  # secretspec.
  dotfiles.tooling.checks.mcp-probe =
    pkgs.runCommand "mcp-probe-check" { nativeBuildInputs = [ pkgs.nushell ]; }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" scripts tests
        cp ${../scripts/mcp.nu} scripts/mcp.nu
        cp ${../scripts/secret.nu} scripts/secret.nu
        cp ${../tests/mcp-probe.nu} tests/mcp-probe.nu
        cp ${../tests/fake-mcp-server.nu} tests/fake-mcp-server.nu
        nu --no-config-file tests/mcp-probe.nu
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
        nu ${../tests/atuin-mcp.nu} ${lib.getExe mcpLegacyHandshake} ${lib.getExe atuin}
        touch "$out"
      '';
}
