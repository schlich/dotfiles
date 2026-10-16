{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  jjHunk = import ./jj-hunk-package.nix { inherit inputs lib pkgs; };
in
{
  # Hunk-level split, commit and squash without an interactive editor. Only
  # workstations import this module, as the agents that split topics run
  # there; servers keep the shell home without it.
  home.packages = [ jjHunk ];

  # jj-hunk's split, commit and squash pass this tool themselves; declaring
  # it also lets `jj split -i --tool=jj-hunk` read JJ_HUNK_SELECTION.
  programs.jujutsu.settings.merge-tools.jj-hunk = {
    program = lib.getExe jjHunk;
    edit-args = [
      "select"
      "$left"
      "$right"
    ];
  };

  dotfiles.nixpkgsWatch.jj-hunk = {
    inherit (jjHunk) version;
    reason = "replace modules/programs/jj-hunk-package.nix with pkgs.jj-hunk in jj-hunk.nix, and drop the jj-hunk input";
  };
}
