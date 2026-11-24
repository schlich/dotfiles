# Checks that run ./mode-hints.nu: a program in a terminal kept by
# nu_plugin_ghostty, entered into each documented mode one key at a time.
{
  inputs,
  lib,
  pkgs,
}:

let
  plugin = import ../../programs/shell/nu-plugin-ghostty/package.nix { inherit inputs lib pkgs; };
in
{
  name,
  # The case in mode-hints.nu: which modes, keys and rows to expect.
  case,
  command,
  setup ? "",
  nativeBuildInputs ? [ ],
}:
pkgs.runCommand "mode-hints-${name}" { nativeBuildInputs = nativeBuildInputs ++ [ pkgs.nushell ]; }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" "$TMPDIR/work"
    cd "$TMPDIR/work"
    ${setup}
    nu --no-config-file --plugins '[${lib.getExe plugin}]' ${./mode-hints.nu} ${case} ${lib.escapeShellArgs command}
    touch "$out"
  ''
