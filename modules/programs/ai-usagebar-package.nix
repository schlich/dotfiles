{
  inputs,
  pkgs,
}:

# ai-usagebar from its own flake, which follows this configuration's nixpkgs.
# rusqlite asks for its bundled SQLite, but since the 2026-11-13 nixpkgs
# libsqlite3-sys links the system library (`-lsqlite3`), and upstream's
# package.nix does not list it. Drop the override once upstream adds sqlite.
inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
  buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.sqlite ];
})
