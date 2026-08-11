{
  imports = [
    ../modules/tooling/terminals/ghostty.nix
    ../modules/tooling/editors/helix.nix
    ../modules/tooling/ai/copilot.nix
  ];

  dotfiles.primary = {
    terminal = "ghostty";
    editor = "helix";
    ai = "copilot";
  };
}
