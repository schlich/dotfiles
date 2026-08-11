{
  imports = [
    ../modules/tooling/terminals/kitty.nix
    ../modules/tooling/editors/helix.nix
    ../modules/tooling/ai/opencode.nix
  ];

  dotfiles.primary = {
    terminal = "kitty";
    editor = "helix";
    ai = "opencode";
  };
}
