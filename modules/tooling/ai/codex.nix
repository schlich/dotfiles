{ pkgs, ... }:

{
  imports = [ ./common.nix ];

  programs.codex = {
    enable = true;
    enableMcpIntegration = true;
  };

  dotfiles.tooling.ai.codex = {
    command = "${pkgs.codex}/bin/codex";
    automation = ''
      ^${pkgs.codex}/bin/codex exec --dangerously-bypass-approvals-and-sandbox $prompt
    '';
  };
}
