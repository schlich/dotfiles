{ inputs, ... }:
{
  den.aspects.user-terminal =
    { host, ... }:
    {
      homeManager.imports = [
        ../../../modules/home/nix.nix
        ../../../modules/home/session.nix
        ../../../modules/programs/cli.nix
        ../../../modules/programs/shell.nix
        ../../../modules/programs/ssh.nix
        ../../../modules/programs/vcs.nix
      ]
      ++ (
        if host.profile.desktop == "niri" then
          [
            inputs.noctalia.homeModules.default
            inputs.codex-desktop-linux.homeManagerModules.default
            ../../../modules/tooling/interface.nix
            ../../../modules/tooling/terminals/kitty.nix
            ../../../modules/tooling/terminals/ghostty.nix
            ../../../modules/tooling/terminals/rio.nix
            ../../../modules/tooling/editors/helix.nix
            ../../../modules/tooling/editors/zed.nix
            ../../../modules/tooling/ai/plugins.nix
            ../../../modules/tooling/ai/opencode-desktop.nix
            ../../../modules/tooling/ai/opencode.nix
            ../../../modules/tooling/ai/claude-code.nix
            ../../../modules/tooling/ai/codex.nix
            ../../../modules/tooling/ai/copilot.nix
            ../../../modules/home/files.nix
            ../../../modules/home/services.nix
            ../../../modules/programs/desktop.nix
          ]
        else
          [ ]
      );
    };
}
