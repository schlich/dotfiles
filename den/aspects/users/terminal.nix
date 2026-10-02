{ inputs, ... }:
{
  den.aspects.user-terminal.homeManager.imports = [
    inputs.codex-desktop-linux.homeManagerModules.default
    ../../../modules/tooling/interface.nix
    ../../../modules/tooling/terminals/kitty.nix
    ../../../modules/tooling/terminals/ghostty.nix
    ../../../modules/tooling/editors/helix.nix
    ../../../modules/tooling/editors/zed.nix
    ../../../modules/tooling/knowledge/iwe.nix
    ../../../modules/tooling/ai/plugins.nix
    ../../../modules/tooling/ai/opencode-desktop.nix
    ../../../modules/tooling/ai/opencode.nix
    ../../../modules/tooling/ai/claude-code.nix
    ../../../modules/tooling/ai/codex.nix
    ../../../modules/tooling/ai/copilot.nix
    ../../../modules/home
    ../../../modules/programs
  ];
}
