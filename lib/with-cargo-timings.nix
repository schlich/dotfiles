# Builds a Rust package with `cargo build --timings` and keeps cargo's report
# in a separate `timings` output, so installing the package does not pull it
# in. The report is an HTML Gantt chart of every crate's compile time:
#
#   nix build path:.#jj-hunk.timings
#   xdg-open result-timings/cargo-timing.html
#
# flake.nix exposes jj-hunk as a package for this.
#
# Only the build phase is timed; the check phase runs its own cargo command.
{ lib }:

drv:
drv.overrideAttrs (old: {
  outputs = lib.unique ((old.outputs or [ "out" ]) ++ [ "timings" ]);
  cargoBuildFlags = lib.toList (old.cargoBuildFlags or [ ]) ++ [ "--timings" ];
  postBuild = (old.postBuild or "") + ''
    mkdir -p "$timings"
    cp -r "''${CARGO_TARGET_DIR:-target}/cargo-timings/." "$timings/"
  '';
})
