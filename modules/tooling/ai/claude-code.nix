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
        let result = (^${pkgs.secretspec}/bin/secretspec get --file ${../../secretspec.toml} --provider keyring --reason "Claude Code GitHub MCP connection" GITHUB_TOKEN | complete)
        let token = ($result.stdout | str trim)
        if $result.exit_code != 0 or ($token | is-empty) {
            print --stderr "GITHUB_TOKEN is not available from secretspec."
            exit 1
        }
        { Authorization: $"Bearer ($token)" } | to json --raw | print
    }
  '';
  preferNushellGuard = pkgs.runCommand "claude-code-prefer-nushell" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "prefer-nushell";
        description = "Ask before Bash calls so shell work defaults to the nushell MCP tool.";
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
                command = "${pkgs.nushell}/bin/nu --stdin ${./scripts/prefer-nushell-bash.nu}";
              }
            ];
          }
        ];
      }
    } $out/hooks/hooks.json
  '';
in
{
  imports = [ ./common.nix ];

  programs.claude-code = {
    enable = true;
    enableMcpIntegration = true;
    # Read-only: GitHub writes go through jj-ci.
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
        tools = "tools: Read, Glob, Grep, Bash";
      } "${agentSource}/trunk-triage.agent.md"
    );
    plugins.jj-guard = jjGuard;
    plugins.jev-bash-guard = jevBashGuard;
    plugins.prefer-nushell = preferNushellGuard;
  };

  dotfiles.tooling = {
    ai.claude-code = {
      command = "${pkgs.claude-code}/bin/claude";
      automation = ''
        ^${pkgs.claude-code}/bin/claude --print --dangerously-skip-permissions $prompt
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
