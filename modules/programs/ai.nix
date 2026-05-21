{ inputs, ... }:

{
  programs.claude-code = {
    enable = true;
    enableMcpIntegration = true;
    marketplaces.marimo-pair = inputs.marimo-pair;
    plugins = [ inputs.marimo-pair ];
    settings = {
      enabledPlugins."marimo-pair@marimo-pair" = true;
      hooks.PreToolUse = [
        {
          matcher = "Bash";
          hooks = [
            {
              type = "command";
              command = ''echo "Bash is disabled here. Use the nu MCP server instead: mcp__plugin_claude-code-home-manager_nu__evaluate for running commands, mcp__plugin_claude-code-home-manager_nu__list_commands to discover, mcp__plugin_claude-code-home-manager_nu__command_help for help. Rewrite the bash invocation as a nushell pipeline and call evaluate." >&2; exit 2'';
            }
          ];
        }
      ];
    };
  };

  programs.codex.enable = true;
  programs.gemini-cli.enable = true;

  programs.mcp = {
    enable = true;
    servers = {
      nu = {
        command = "nu";
        args = [ "--mcp" ];
      };
      nix = {
        command = "uvx";
        args = [ "mcp-nixos" ];
      };
    };
  };

  programs.opencode = {
    enable = true;
    package = inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.default;
    enableMcpIntegration = true;
    skills.marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
    settings.tools.bash = false;
  };
}
