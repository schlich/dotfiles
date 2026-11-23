{
  lib,
  honeycomb,
  root,
}:

# Counts the collections this repository asks a person to hold in mind, with
# honeycomb's counters (github:schlich/honeycomb): every directory's entries,
# the flake's inputs and input groups, niri's binds and window rules, and the
# sections of AGENTS.md. The honeycomb-census flake check audits the result
# against baseline.nix.
let
  inherit (honeycomb) census;
  niri = (import (root + "/niri/binds.nix") { inherit lib honeycomb; }).tree;
in
census.directories { inherit root; }
// census.cells "niri" niri
// census.flakeInputs (root + "/flake.lock")
// {
  "niri:window-rules" = census.matching "window-rule .*" (root + "/niri/config.kdl");
  "agents:sections" = census.matching "## .*" (root + "/AGENTS.md");
}
