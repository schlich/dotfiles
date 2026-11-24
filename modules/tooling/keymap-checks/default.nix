{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# The keymap rules, checked in the configured terminal programs two ways:
#
# - Bombadil types at random and checks that the current mode stays on
#   screen, a prefix key shows the keys that follow it, and Esc returns to
#   the base mode. The specifications are in tests/bombadil.
# - ./mode-hints.nu enters each documented mode one key at a time, through
#   nu_plugin_ghostty, and checks the mode label and the hint line's keys
#   against the documentation.
#
# Both run with this home's other tooling checks in the flake's home-manager
# check. Programs that do not follow the rules yet are checked in ./remote.nix,
# which reports from remoteChecks without gating a landing.
let
  bombadil = import ../../../lib/bombadil.nix { inherit lib pkgs; };
  modeHints = import ./mode-hints.nix { inherit inputs lib pkgs; };
  fieldnotes = import ../ai/claude/fieldnotes-package.nix { inherit inputs pkgs; };
  # Offline in the build sandbox, every Fieldnotes source fails at once and
  # its panel shows the error; the modes and keys work all the same.
  fieldnotesSetup = ''
    export XDG_STATE_HOME="$HOME/.local/state" FIELDNOTES_POLL_SECONDS=600
  '';
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

      fieldnotes-keymap = bombadil.terminalCheck {
        name = "fieldnotes-keymap";
        specification = "fieldnotes.ts";
        command = [ (lib.getExe fieldnotes) ];
        setup = fieldnotesSetup;
      };

      fieldnotes-mode-hints = modeHints {
        name = "fieldnotes";
        case = "fieldnotes";
        command = [ (lib.getExe fieldnotes) ];
        setup = fieldnotesSetup;
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
