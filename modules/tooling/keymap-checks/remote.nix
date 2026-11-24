# Keymap checks of programs that do not follow the keymap rules yet, for the
# flake's remoteChecks: GitHub Actions reports them after each push without
# gating a landing. Move a program's checks to ./default.nix once they pass.
#
# jjui (programs.jjui, with its default settings) names its base mode
# `revisions` rather than NORMAL, and its help (`?`) and command prompt (`:`)
# show no mode, so both of its checks fail until it changes.
{
  inputs,
  lib,
  pkgs,
}:

let
  bombadil = import ../../../lib/bombadil.nix { inherit lib pkgs; };
  modeHints = import ./mode-hints.nix { inherit inputs lib pkgs; };
  jj = lib.getExe pkgs.jujutsu;
  # A repository with two changes, and jj on jjui's PATH.
  jjuiSetup = ''
    export JJ_USER=Tester JJ_EMAIL=tester@example.com
    ${jj} git init --quiet .
    printf 'one\n' > a.txt
    ${jj} describe --quiet -m "first change"
    ${jj} new --quiet -m "second change"
  '';
  jjui = [
    "${pkgs.coreutils}/bin/env"
    "PATH=${lib.makeBinPath [ pkgs.jujutsu ]}"
    (lib.getExe pkgs.jjui)
  ];
in
{
  jjui-keymap = bombadil.terminalCheck {
    name = "jjui-keymap";
    specification = "jjui.ts";
    command = jjui;
    setup = jjuiSetup;
  };

  jjui-mode-hints = modeHints {
    name = "jjui";
    case = "jjui";
    command = jjui;
    setup = jjuiSetup;
  };
}
