{
  inputs,
  lib,
  username,
  homeDirectory,
  stateVersion ? "26.05",
  codexDesktopLinux ? false,
  ...
}:
{
  imports = [
    inputs.noctalia.homeModules.default
    ./modules/tooling/interface.nix
    ./modules/tooling/terminals/kitty.nix
    ./modules/tooling/terminals/ghostty.nix
    ./modules/tooling/terminals/rio.nix
    ./modules/tooling/editors/helix.nix
    ./modules/tooling/editors/zed.nix
    ./modules/tooling/ai/plugins.nix
    ./modules/tooling/ai/opencode-desktop.nix
    ./modules/tooling/ai/opencode.nix
    ./modules/tooling/ai/claude-code.nix
    ./modules/tooling/ai/codex.nix
    ./modules/tooling/ai/copilot.nix
    ./modules/tooling/ai/antigravity.nix
    ./modules/home
    ./modules/programs
  ]
  ++ lib.optionals codexDesktopLinux [
    inputs.codex-desktop-linux.homeManagerModules.default
  ];

  manual.manpages.enable = false;
  home = {
    inherit username homeDirectory stateVersion;
  };

  dotfiles.primary = {
    terminal = "ghostty";
    editor = "helix";
    ai = "opencode";
  };
}
// lib.optionalAttrs codexDesktopLinux {
  programs.codexDesktopLinux.enable = true;
}
