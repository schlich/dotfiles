{
  inputs,
  lib,
  pkgs,
}:

# Fieldnotes, the dashboard for agent usage, CI, waiting topics, background
# tasks, and recent notes, with the commands its panels read from: gh, the
# ai-usagebar this configuration pins, and the current IWE.
let
  system = pkgs.stdenv.hostPlatform.system;
in
inputs.fieldnotes.packages.${system}.default.override {
  runtimeTools = [
    pkgs.gh
    (import ../../../programs/desktop/ai-usagebar-package.nix { inherit inputs pkgs; })
    (import ../../knowledge/iwe-package.nix { inherit inputs lib pkgs; })
  ];
}
