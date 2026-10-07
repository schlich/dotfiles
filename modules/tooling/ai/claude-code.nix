{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  agentSource = ../../../copilot/plugins/jj-flake-vigilance/agents;
  # Copilot agents use display names, Copilot tool IDs, and GPT models.
  # Rewrite only the frontmatter keys Claude Code interprets differently.
  adaptAgent =
    overrides: file:
    lib.concatMapStringsSep "\n" (
      line:
      let
        key = lib.head (lib.splitString ":" line);
      in
      overrides.${key} or line
    ) (lib.splitString "\n" (builtins.readFile file));

  # Claude Code rewrites ~/.claude/settings.json at runtime, so hooks ship in
  # a personal plugin instead of programs.claude-code.settings.
  jjGuard = pkgs.runCommand "claude-code-jj-guard" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "jj-guard";
        description = "Deny mutating git commands so repository writes go through jj.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = "${pkgs.nushell}/bin/nu --stdin ${../../../copilot/plugins/jj-flake-vigilance/scripts/guard-git-writes.nu} --claude";
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
  contextStatus = import ../../../jj/context-status.nix { inherit pkgs; };
  # Hand each new or resumed session the workspace's topic, lifecycle stage,
  # lint and pipeline state, and next `ci` step.
  contextStatusHandoff = pkgs.runCommand "claude-code-context-status" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "context-status";
        description = "Add the JJ workspace's context status to each session.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.SessionStart = [
          {
            matcher = "startup|resume|clear|compact";
            hooks = [
              {
                type = "command";
                command = "${contextStatus}/bin/context-status handoff --hook";
                timeout = 10;
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
  jev = import ../../../jev/package.nix { inherit pkgs; };
  jevBashGuard = pkgs.runCommand "claude-code-jev-bash-guard" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "jev-bash-guard";
        description = "Ask Jev to route Claude Code Bash commands through Nushell or user confirmation.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = "${jev}/bin/jev bash-guard";
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
  # Fetch the token per connection so it never enters Claude Code's
  # environment, where every shell command could read it.
  githubMcpHeaders = pkgs.writeNuScriptBin "claude-github-mcp-headers" ''
    def main [] {
        let result = (^${pkgs.secretspec}/bin/secretspec get --file ${../../secretspec.toml} --provider keyring --profile default --reason "Claude Code GitHub MCP connection" GITHUB_TOKEN | complete)
        let token = ($result.stdout | str trim)
        if $result.exit_code != 0 or ($token | is-empty) {
            print --stderr "GITHUB_TOKEN is not available from secretspec."
            exit 1
        }
        { Authorization: $"Bearer ($token)" } | to json --raw | print
    }
  '';
  # Deny foreground Bash outside bash-policy.nuon and log every request and
  # outcome; the bash-feedback skill reviews the log with claude-bash-audit,
  # and a Stop hook starts it when a session logs a new use case.
  preferNushellGuard =
    let
      hook = {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${pkgs.nushell}/bin/nu --stdin ${./scripts/prefer-nushell-bash.nu} --policy ${./bash-policy.nuon}";
          }
        ];
      };
    in
    pkgs.runCommand "claude-code-prefer-nushell" { } ''
      install -Dm644 ${
        pkgs.writers.writeJSON "plugin.json" {
          name = "prefer-nushell";
          description = "Deny foreground Bash so shell work defaults to the nushell MCP tool, and log every Bash request.";
        }
      } $out/.claude-plugin/plugin.json
      install -Dm644 ${
        pkgs.writers.writeJSON "hooks.json" {
          hooks = {
            PreToolUse = [ hook ];
            PostToolUse = [ hook ];
            PostToolUseFailure = [ hook ];
            # Raise each never-reviewed Bash use case once, at the end of the
            # turn that logged it, so the agent runs bash-feedback with the user.
            Stop = [
              {
                hooks = [
                  {
                    type = "command";
                    command = "${pkgs.nushell}/bin/nu --stdin ${./scripts/claude-bash-audit.nu} stop-hook";
                    timeout = 10;
                  }
                ];
              }
            ];
          };
        }
      } $out/hooks/hooks.json
    '';
  bashAudit = pkgs.writeNuScriptBin "claude-bash-audit" (
    builtins.readFile ./scripts/claude-bash-audit.nu
  );
  # Record background Bash tasks for the homelab Fieldnotes wallpaper;
  # agent-tasks-push marks them finished and copies the list there.
  backgroundTasks = pkgs.runCommand "claude-code-background-tasks" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "background-tasks";
        description = "Record background Bash tasks for the Fieldnotes wallpaper.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.PostToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = "${pkgs.nushell}/bin/nu --stdin ${../../../agent-monitor/record-background-task.nu}";
                timeout = 5;
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
  pushBackgroundTasks = pkgs.writeNuScriptBin "push-background-tasks" (
    builtins.readFile ../../../agent-monitor/push-background-tasks.nu
  );
  # MCP calls render as a bare `input:` argument; echo the full command before
  # a Nushell evaluation and a one-line result summary after it. The desktop
  # app's tool card already shows the command, so there only the summary runs.
  nushellDisplay =
    let
      hook = {
        matcher = "mcp__.*nushell__evaluate";
        hooks = [
          {
            type = "command";
            command = "${pkgs.nushell}/bin/nu --stdin ${./scripts/nushell-evaluate-display.nu}";
            timeout = 5;
          }
        ];
      };
    in
    pkgs.runCommand "claude-code-nushell-display" { } ''
      install -Dm644 ${
        pkgs.writers.writeJSON "plugin.json" {
          name = "nushell-display";
          description = "Show each Nushell MCP evaluation's command and a result summary.";
        }
      } $out/.claude-plugin/plugin.json
      install -Dm644 ${
        pkgs.writers.writeJSON "hooks.json" {
          hooks = {
            PreToolUse = [ hook ];
            PostToolUse = [ hook ];
            PostToolUseFailure = [ hook ];
          };
        }
      } $out/hooks/hooks.json
    '';
in
{
  imports = [ ./common.nix ];

  home.packages = [ bashAudit ];

  programs.claude-code = {
    enable = true;
    enableMcpIntegration = true;
    # Read-only: GitHub writes go through ci.
    mcpServers.github = {
      type = "http";
      url = "https://api.githubcopilot.com/mcp/readonly";
      headers = {
        X-MCP-Readonly = "true";
        X-MCP-Toolsets = "repos,issues,pull_requests,actions";
      };
      headersHelper = "${githubMcpHeaders}/bin/claude-github-mcp-headers";
    };
    settings = { };
    context = ./global-agent-instructions.md;
    skills = import ./shared-skills.nix { inherit inputs; };
    agents.trunk-triage = lib.replaceStrings [ "Use GPT-5.6 Luna for" ] [ "Use this agent for" ] (
      adaptAgent {
        name = "name: trunk-triage";
        model = "model: haiku";
        # Foreground Bash is denied; shell work goes through Nushell.
        tools = "tools: Read, Glob, Grep, Bash, mcp__plugin_hm_nushell__evaluate";
      } "${agentSource}/trunk-triage.agent.md"
    );
    plugins.jj-guard = jjGuard;
    plugins.jev-bash-guard = jevBashGuard;
    plugins.prefer-nushell = preferNushellGuard;
    plugins.nushell-display = nushellDisplay;
    plugins.context-status = contextStatusHandoff;
    plugins.background-tasks = backgroundTasks;
    # IWE memory: inert outside a workspace whose root has a MEMORY.md policy.
    plugins.iwe = "${inputs.iwe-skills}";
  };

  # Claude Code only reads keybindings.json, so it can be managed. The
  # terminal takes Ctrl+Enter for fullscreen, so Alt+Enter also sends now.
  home.file.".claude/keybindings.json".text = builtins.toJSON {
    "$schema" = "https://www.schemastore.org/claude-code-keybindings.json";
    "$docs" = "https://code.claude.com/docs/en/keybindings";
    bindings = [
      {
        context = "Chat";
        bindings."alt+enter" = "chat:sendNow";
      }
    ];
  };

  # The hook also starts this unit, so a new task appears within seconds;
  # the timer notices finished tasks and keeps homelab's copy fresh.
  systemd.user.services.agent-tasks-push = {
    Unit.Description = "Copy Claude Code background tasks to the homelab wallpaper";
    Service = {
      Type = "oneshot";
      ExecStart = "${pushBackgroundTasks}/bin/push-background-tasks --target homelab";
      Environment = [
        "PATH=${lib.makeBinPath [ pkgs.openssh ]}"
        "SSH_AUTH_SOCK=%t/gcr/ssh"
      ];
    };
  };
  systemd.user.timers.agent-tasks-push = {
    Unit.Description = "Refresh the homelab wallpaper's Claude Code background tasks";
    Timer = {
      OnStartupSec = "30s";
      OnUnitActiveSec = "20s";
      AccuracySec = "1s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  dotfiles.tooling = {
    ai.claude-code = {
      command = "${pkgs.claude-code}/bin/claude";
      # Nobody is present to answer the bash-feedback Stop hook.
      automation = ''
        with-env { CLAUDE_BASH_FEEDBACK: off } { ^${pkgs.claude-code}/bin/claude --print --dangerously-skip-permissions $prompt }
      '';
    };
    # Run the generated hook commands from Node, as the agent CLIs do.
    checks.pretooluse-hooks =
      pkgs.runCommand "pretooluse-hooks-check"
        {
          nativeBuildInputs = [
            pkgs.nodejs
            pkgs.nushell
          ];
        }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          node ${./tests/pretooluse-hooks.mjs} \
            jj-guard=${jjGuard} \
            prefer-nushell=${preferNushellGuard} \
            jev-bash-guard=${jevBashGuard} \
            copilot-guard=${../../../copilot/plugins/jj-flake-vigilance}
          touch "$out"
        '';
  };
}
