{ pkgs, ... }:

let
  codexJjSession = pkgs.writeNuScriptBin "codex-jj-session" (
    builtins.readFile ../../jj/codex-session.nu
  );
  codexConfig = (pkgs.formats.toml { }).generate "codex-system-config" {
    hooks = {
      SessionStart = [
        {
          matcher = "startup|resume";
          hooks = [
            {
              type = "command";
              command = "${codexJjSession}/bin/codex-jj-session session-start";
              timeout = 10;
              statusMessage = "Checking JJ topic ownership";
            }
          ];
        }
      ];
      PreToolUse = [
        {
          hooks = [
            {
              type = "command";
              command = "${codexJjSession}/bin/codex-jj-session guard";
              timeout = 10;
              statusMessage = "Checking JJ topic ownership";
            }
          ];
        }
      ];
      UserPromptSubmit = [
        {
          hooks = [
            {
              type = "command";
              command = "${codexJjSession}/bin/codex-jj-session first-prompt";
              timeout = 120;
              statusMessage = "Checking and naming the JJ topic";
            }
          ];
        }
      ];
    };
    mcp_servers = {
      chrome-devtools = {
        command = "npx";
        args = [
          "-y"
          "chrome-devtools-mcp@latest"
        ];
      };
      github = {
        url = "https://api.githubcopilot.com/mcp/";
        bearer_token_env_var = "GITHUB_TOKEN";
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
        command = "nu";
        args = [ "--mcp" ];
      };
    };
  };
in
{
  environment.systemPackages = [ codexJjSession ];
  environment.etc."codex/config.toml".source = codexConfig;
}
