{ pkgs, ... }:

{
  imports = [ ./common.nix ];

  programs.claude-code = {
    enable = true;
    enableMcpIntegration = true;
    settings = { };
  };

  dotfiles.tooling.ai.claude-code = {
    command = "${pkgs.claude-code}/bin/claude";
    automation = ''
      ^${pkgs.claude-code}/bin/claude --print --dangerously-skip-permissions $prompt
    '';
  };
}
