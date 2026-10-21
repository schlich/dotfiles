{ lib, pkgs, ... }:

# `ci-trace` reads the Nix build traces that nix-ci's flake-check action
# uploads (tools/ci-trace): `report` ranks the derivations CI spent the most
# time building across recent runs, and `run` merges one run into a
# Perfetto trace. docs/ci-tracing.md describes the pipeline.
let
  ciTrace = pkgs.writeShellApplication {
    name = "ci-trace";
    runtimeInputs = [ pkgs.gh ];
    text = ''
      exec ${lib.getExe pkgs.nushell} --no-config-file ${../../tools/ci-trace/ci-trace.nu} "$@"
    '';
    meta.description = "Rank and inspect nix-ci's Nix build traces";
  };
in
{
  home.packages = [ ciTrace ];
}
