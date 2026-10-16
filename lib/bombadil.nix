# Bombadil, Antithesis's property-based tester for terminal and web UIs,
# and checks that explore a program against a TypeScript specification in
# tests/bombadil. nixpkgs lacks it; the release binary is static.
{ lib, pkgs }:

let
  version = "0.7.9";

  package = pkgs.stdenvNoCC.mkDerivation {
    pname = "bombadil";
    inherit version;
    src = pkgs.fetchurl {
      url = "https://github.com/antithesishq/bombadil/releases/download/v${version}/bombadil-x86_64-linux";
      hash = "sha256-OvSrM+AnPeJFW1T9e8aHyHQrdBHbhsllw8094w+dXN4=";
    };
    dontUnpack = true;
    installPhase = ''
      install -Dm755 "$src" "$out/bin/bombadil"
    '';
    meta = {
      description = "Property-based testing for web and terminal UIs";
      homepage = "https://github.com/antithesishq/bombadil";
      license = lib.licenses.mit;
      mainProgram = "bombadil";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  };

  specifications = lib.fileset.toSource {
    root = ../tests/bombadil;
    fileset = ../tests/bombadil;
  };
in
{
  inherit package;

  # For dotfiles.nixpkgsWatch.bombadil in each module that runs a check.
  watch = {
    inherit version;
    reason = "lib/bombadil.nix fetches the release binary; take pkgs.bombadil there instead.";
  };

  # Explores `command` in a terminal for `timeLimit` and fails on the first
  # property violation, printing the screen it saw. Exploration is random,
  # so a check that passed is cached until its program or specification
  # changes. To replay a failure, rebuild with --keep-failed and run
  # `bombadil terminal test --reproduce` on the kept trace.
  terminalCheck =
    {
      name,
      specification,
      command,
      timeLimit ? "30s",
      setup ? "",
    }:
    pkgs.runCommand "bombadil-${name}" { nativeBuildInputs = [ package ]; } ''
      # Openers and pagers return at once, so the program stays in front.
      export HOME="$TMPDIR/home" EDITOR=true PAGER=true
      mkdir -p "$HOME" "$TMPDIR/work"
      cd "$TMPDIR/work"
      ${setup}
      # Bombadil logs every state; keep the log out of the build output.
      if ! bombadil terminal test \
        --exit-on-violation \
        --time-limit ${timeLimit} \
        --quiescence-timeout-ms 20 \
        --specification ${specifications}/${specification} \
        --output-path "$TMPDIR/trace" \
        -- ${lib.escapeShellArgs command} >"$TMPDIR/bombadil.log"; then
        tail -n 80 "$TMPDIR/bombadil.log"
        echo "Trace: $TMPDIR/trace (rebuild with --keep-failed to keep it)"
        exit 1
      fi
      tail -n 3 "$TMPDIR/bombadil.log"
      touch "$out"
    '';
}
