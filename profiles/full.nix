{
  imports = [
    ../modules/tooling/terminals/kitty.nix
    ../modules/tooling/terminals/ghostty.nix
    ../modules/tooling/terminals/rio.nix
    ../modules/tooling/editors/helix.nix
    ../modules/tooling/editors/zed.nix
    ../modules/tooling/ai/opencode.nix
    ../modules/tooling/ai/claude-code.nix
    ../modules/tooling/ai/codex.nix
    ../modules/tooling/ai/copilot.nix
  ];

  dotfiles.primary = {
    terminal = "kitty";
    editor = "helix";
    ai = "opencode";
  };
}
