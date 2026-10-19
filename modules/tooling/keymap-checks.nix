{
  config,
  lib,
  pkgs,
  ...
}:

# Bombadil types at random into the configured terminal programs and checks
# the keymap rules: the current mode stays on screen, a prefix key shows the
# keys that follow it, and Esc returns to the base mode. The specifications
# are in tests/bombadil; the checks run with this home's other tooling checks
# in the flake's home-manager check.
let
  bombadil = import ../../lib/bombadil.nix { inherit lib pkgs; };
in
{
  dotfiles.tooling.checks = lib.mkMerge [
    {
      yazi-keymap = bombadil.terminalCheck {
        name = "yazi-keymap";
        specification = "yazi.ts";
        command = [
          (lib.getExe config.programs.yazi.package)
          "."
        ];
        setup = ''
          mkdir docs
          printf 'hello\n' > a.txt
          printf 'notes\n' > docs/b.txt
        '';
      };
    }
    (lib.mkIf config.programs.helix.enable {
      helix-keymap = bombadil.terminalCheck {
        name = "helix-keymap";
        specification = "helix.ts";
        command = [
          (lib.getExe config.programs.helix.package)
          "notes.txt"
        ];
        setup = ''
          printf 'one\ntwo\nthree\n' > notes.txt
        '';
      };
    })
  ];

  dotfiles.nixpkgsWatch.bombadil = bombadil.watch;
}
