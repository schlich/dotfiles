{ pkgs, ... }:

let
  codexConfig = (pkgs.formats.toml { }).generate "codex-system-config" {
    # JJ has no global non-interactive environment switch. Codex shell tools
    # are non-interactive, so prevent an accidental editor or pager from
    # blocking them while leaving interactive terminals unchanged.
    shell_environment_policy.set = {
      JJ_EDITOR = "${pkgs.coreutils}/bin/true";
      PAGER = "${pkgs.coreutils}/bin/cat";
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
      atuin = {
        command = "atuin";
        args = [ "mcp" ];
      };
    };
  };
in
{
  environment.etc."codex/config.toml".source = codexConfig;
}
