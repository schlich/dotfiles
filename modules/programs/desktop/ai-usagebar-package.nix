{
  inputs,
  pkgs,
}:

# ai-usagebar from its own flake, which follows this configuration's nixpkgs.
# rusqlite asks for its bundled SQLite, but since the 2026-11-13 nixpkgs
# libsqlite3-sys links the system library (`-lsqlite3`), and upstream's
# package.nix does not list it. Drop the override once upstream adds sqlite.
#
# Its test suite is skipped: on homelab, compiling the test binaries prints
# nothing for longer than nixbot's 20-minute silence limit, so the desktop
# home gate timed out. The suite passed on asus with 1.52.2 (2026-11-17).
#
# Upstream's nix/package.nix wraps procps and xdg-utils into PATH, but omits
# libsecret (`secret-tool`), which ai-usagebar shells out to on Linux to read
# Antigravity's saved Google session from the Secret Service keyring once the
# Antigravity app is closed. Appending antigravity-cli (`agy`) alongside it
# keeps restricted-PATH callers (such as usage-reset-alert and fieldnotes) on
# `agy -p /quota` instead of falling back to the Cloud Code API and clobbering
# the shared Antigravity cache.
let
  upstream =
    inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs
      (old: {
        buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.sqlite ];
        doCheck = false;
      });
  runtimePath = pkgs.lib.makeBinPath [
    pkgs.libsecret
    pkgs.antigravity-cli
  ];
in
pkgs.symlinkJoin {
  name = "ai-usagebar-${upstream.version}";
  paths = [ upstream ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  inherit (upstream) meta;
  postBuild = ''
    for program in ai-usagebar ai-usagebar-tui; do
      rm "$out/bin/$program"
      makeWrapper "${upstream}/bin/$program" "$out/bin/$program" \
        --suffix PATH : "${runtimePath}"
    done
  '';
}
