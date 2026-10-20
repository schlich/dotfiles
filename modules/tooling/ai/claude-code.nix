{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # Repositories driven through Git and luvus: the jj write guard and ci's
  # context-status hooks leave sessions in them alone.
  gitRepos = config.dotfiles.tooling.gitWorkflowRepos;
  skipInGitRepos =
    hookCommand:
    "${pkgs.nushell}/bin/nu --stdin ${./scripts/skip-in-git-repos.nu} --repos ${lib.escapeShellArg (builtins.toJSON gitRepos)} ${hookCommand}";
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
        # Foreground Bash is denied, so most shell work arrives as Nushell.
        hooks.PreToolUse = [
          {
            matcher = "Bash|mcp__.*nushell__evaluate";
            hooks = [
              {
                type = "command";
                command = "${pkgs.nushell}/bin/nu --stdin ${../../../copilot/plugins/jj-flake-vigilance/scripts/guard-git-writes.nu} --claude ${lib.escapeShellArgs gitRepos}";
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
  contextStatus = inputs.ci.packages.${pkgs.stdenv.hostPlatform.system}.context-status;
  # Hand each new or resumed session the workspace's topic, lifecycle stage,
  # lint and pipeline state, and next `ci` step. Concurrent sessions that
  # shared one checkout moved each other's working copy and split changes into
  # divergent copies, so a session's first edit claims a workspace idle on
  # trunk, the default checkout included, and edits to another session's
  # workspace, to a topic nobody handed over, or from a session's Git
  # worktree are refused.
  contextStatusHandoff = pkgs.runCommand "claude-code-context-status" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "context-status";
        description = "Add the JJ workspace's context status to each session, and claim a free workspace on a session's first edit.";
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
                command = skipInGitRepos "${contextStatus}/bin/context-status handoff --hook";
                timeout = 10;
              }
            ];
          }
        ];
        hooks.PreToolUse = [
          {
            matcher = "Edit|MultiEdit|Write|NotebookEdit";
            hooks = [
              {
                type = "command";
                command = skipInGitRepos "${contextStatus}/bin/context-status guard";
                timeout = 10;
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
  jev = import ../../../jev/package.nix { inherit pkgs; };
  # Learn from your permission-dialog answers which kinds of tool call you
  # approve, and answer the dialog for classes promoted in trust-policy.nuon.
  agentTrustSource =
    builtins.replaceStrings
      [ "@policy@" "@questions@" "@jev@" ]
      [ "${./trust-policy.nuon}" "${../../../jev/questions.nuon}" "${jev}/bin/jev" ]
      (builtins.readFile ./scripts/agent-trust.nu);
  agentTrustScript = pkgs.writeText "agent-trust.nu" agentTrustSource;
  agentTrust =
    let
      outcome = {
        hooks = [
          {
            type = "command";
            command = "${pkgs.nushell}/bin/nu --stdin ${agentTrustScript} outcome";
            async = true;
            timeout = 10;
          }
        ];
      };
    in
    pkgs.runCommand "claude-code-agent-trust" { } ''
      install -Dm644 ${
        pkgs.writers.writeJSON "plugin.json" {
          name = "agent-trust";
          description = "Learn which permission dialogs you approve and answer promoted ones.";
        }
      } $out/.claude-plugin/plugin.json
      install -Dm644 ${
        pkgs.writers.writeJSON "hooks.json" {
          hooks = {
            PermissionRequest = [
              {
                matcher = "*";
                hooks = [
                  {
                    type = "command";
                    command = "${pkgs.nushell}/bin/nu --stdin ${agentTrustScript} permission-request";
                    timeout = 30;
                  }
                ];
              }
            ];
            PostToolUse = [ outcome ];
            PostToolUseFailure = [ outcome ];
          };
        }
      } $out/hooks/hooks.json
    '';
  agentTrustBin = pkgs.writeNuScriptBin "agent-trust" agentTrustSource;
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
  stitchMcpHeaders = pkgs.writeNuScriptBin "claude-stitch-mcp-headers" ''
    def main [] {
        let result = (^${pkgs.secretspec}/bin/secretspec get --file ${../../secretspec.toml} --provider keyring --profile default --reason "Claude Code Stitch MCP connection" STITCH_API_KEY | complete)
        let key = ($result.stdout | str trim)
        if $result.exit_code != 0 or ($key | is-empty) {
            print --stderr "STITCH_API_KEY is not available from secretspec."
            exit 1
        }
        { X-Goog-Api-Key: $key } | to json --raw | print
    }
  '';
  # Deny foreground Bash outside bash-policy.nuon, ask Jev about the calls the
  # policy leaves open, and log every request and outcome. One hook decides
  # each call, so the agent sees the reason of the guard that decided it and
  # Jev runs only on calls the policy defers. The bash-feedback skill reviews
  # the log with claude-bash-audit, and a Stop hook starts it when a session
  # logs a new use case.
  preferNushellGuard =
    let
      hook = {
        matcher = "Bash";
        hooks = [
          {
            type = "command";
            command = "${pkgs.nushell}/bin/nu --stdin ${./scripts/prefer-nushell-bash.nu} --policy ${./bash-policy.nuon} --jev ${jev}/bin/jev";
          }
        ];
      };
    in
    pkgs.runCommand "claude-code-prefer-nushell" { } ''
      install -Dm644 ${
        pkgs.writers.writeJSON "plugin.json" {
          name = "prefer-nushell";
          description = "Deny foreground Bash so shell work defaults to the nushell MCP tool, ask Jev about the rest, and log every Bash request.";
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
                    command = "${pkgs.nushell}/bin/nu --stdin ${bashAuditScript} stop-hook";
                    timeout = 10;
                  }
                ];
              }
            ];
          };
        }
      } $out/hooks/hooks.json
    '';
  # `report --jev` suggests each cluster's remedy with the `bash_feedback`
  # questions in jev/questions.nuon.
  bashAuditSource =
    builtins.replaceStrings
      [ "@questions@" "@jev@" ]
      [ "${../../../jev/questions.nuon}" "${jev}/bin/jev" ]
      (builtins.readFile ./scripts/claude-bash-audit.nu);
  bashAuditScript = pkgs.writeText "claude-bash-audit.nu" bashAuditSource;
  bashAudit = pkgs.writeNuScriptBin "claude-bash-audit" bashAuditSource;
  # Record background Bash tasks and Monitors (which follow Nushell jobs) for
  # the homelab Fieldnotes wallpaper; agent-tasks-push marks them finished and
  # copies the list there.
  backgroundTasks = pkgs.runCommand "claude-code-background-tasks" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "background-tasks";
        description = "Record background Bash tasks and Monitors for the Fieldnotes wallpaper.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.PostToolUse = [
          {
            matcher = "Bash|Monitor";
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
  # Remind the agent, once per session and kind, to answer Nix package, option,
  # and pinned-source questions with the Nix MCP server rather than by hand.
  preferNixMcpCommand = "${pkgs.nushell}/bin/nu --stdin ${./scripts/prefer-nix-mcp.nu}";
  preferNixMcp = pkgs.runCommand "claude-code-prefer-nix-mcp" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "prefer-nix-mcp";
        description = "Point Nix lookups done by hand at the Nix MCP server.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.PostToolUse = [
          {
            matcher = "Bash|Read|Glob|Grep|mcp__.*nushell__evaluate";
            hooks = [
              {
                type = "command";
                command = preferNixMcpCommand;
                timeout = 5;
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
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
  # Report each session's id and lifecycle to Luvus, as
  # `luvus integration install claude` would, without its python3 dependency
  # or an entry in the runtime settings.json. Inert outside a Luvus pane.
  luvus = inputs.luvus.packages.${pkgs.stdenv.hostPlatform.system}.default;
  luvusHook =
    let
      hook = {
        hooks = [
          {
            type = "command";
            command = "${pkgs.nushell}/bin/nu --stdin ${./scripts/luvus-hook.nu} --luvus ${lib.getExe luvus}";
            timeout = 5;
          }
        ];
      };
    in
    pkgs.runCommand "claude-code-luvus" { } ''
      install -Dm644 ${
        pkgs.writers.writeJSON "plugin.json" {
          name = "luvus";
          description = "Report session ids and lifecycle events to Luvus for exact resume and agent state.";
        }
      } $out/.claude-plugin/plugin.json
      install -Dm644 ${
        pkgs.writers.writeJSON "hooks.json" {
          hooks = {
            SessionStart = [ hook ];
            Notification = [ hook ];
            Stop = [ hook ];
            UserPromptSubmit = [ hook ];
          };
        }
      } $out/hooks/hooks.json
    '';
in
{
  imports = [ ./common.nix ];

  home.packages = [
    bashAudit
    agentTrustBin
  ];

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
    mcpServers.stitch = {
      type = "http";
      url = "https://stitch.googleapis.com/mcp";
      headersHelper = "${stitchMcpHeaders}/bin/claude-stitch-mcp-headers";
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
    plugins.prefer-nushell = preferNushellGuard;
    plugins.agent-trust = agentTrust;
    plugins.nushell-display = nushellDisplay;
    plugins.context-status = contextStatusHandoff;
    plugins.background-tasks = backgroundTasks;
    plugins.prefer-nix-mcp = preferNixMcp;
    plugins.luvus = luvusHook;
    # IWE memory: inert outside a workspace whose root has a MEMORY.md policy.
    plugins.iwe = "${inputs.iwe-skills}";
  };

  # Draw each Nushell evaluation as a card titled by its `# comment`, and
  # stream a `job-log` job's log into its card and its Monitor's. Claude Code
  # loads a plugin folder under ~/.claude/skills, as programs.claude-code.plugins
  # places them, but that option links each top-level entry to the store on
  # its own, which leaves the `types` contract outside the plugin's folder and
  # gets the plugin refused. Link the folder whole instead.
  home.file.".claude/skills/nushell-cards".source = ./claude-plugins/nushell-cards;

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
            jev=${jev} \
            agent-trust=${agentTrust} \
            copilot-guard=${../../../copilot/plugins/jj-flake-vigilance}
          touch "$out"
        '';
    # claude-bash-audit's report with a stub jev, so no request leaves.
    checks.claude-bash-audit =
      pkgs.runCommand "claude-bash-audit-check" { nativeBuildInputs = [ pkgs.nushell ]; }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          nu --no-config-file ${./tests/claude-bash-audit.nu} ${./scripts/claude-bash-audit.nu} ${../../../jev/questions.nuon}
          touch "$out"
        '';
    checks.prefer-nix-mcp-hook =
      pkgs.runCommand "prefer-nix-mcp-hook-check" { nativeBuildInputs = [ pkgs.nushell ]; }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          nu ${./tests/prefer-nix-mcp.nu} ${lib.escapeShellArg preferNixMcpCommand}
          touch "$out"
        '';
    # The jj write guard and the context-status wrapper, against scratch
    # repositories with a linked worktree.
    checks.git-workflow-repos =
      pkgs.runCommand "git-workflow-repos-check"
        {
          nativeBuildInputs = [
            pkgs.nushell
            pkgs.git
          ];
        }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          nu --no-config-file ${./tests/guard-git-writes.nu} ${../../../copilot/plugins/jj-flake-vigilance/scripts/guard-git-writes.nu}
          nu --no-config-file ${./tests/skip-in-git-repos.nu} ${./scripts/skip-in-git-repos.nu}
          touch "$out"
        '';
    checks.luvus-hook = pkgs.runCommand "luvus-hook-check" { nativeBuildInputs = [ pkgs.nushell ]; } ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      nu --no-config-file ${./tests/luvus-hook.nu} ${./scripts/luvus-hook.nu}
      touch "$out"
    '';
    # The test kit runs each test file in a child of the CLI, offline.
    checks.nushell-cards-mod =
      pkgs.runCommand "nushell-cards-mod-check" { nativeBuildInputs = [ pkgs.claude-code ]; }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          claude plugin validate --strict ${./claude-plugins/nushell-cards}
          claude plugin test ${./claude-plugins/nushell-cards}
          touch "$out"
        '';
  };
}
