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

  # Which properties failed and when. The tail of the log that follows holds
  # only the last states, which for a long state can start below the name.
  violations = ''
    grep -E ' was violated:$|however at [0-9:.]+:$' "$TMPDIR/bombadil.log" | cut -c1-200 || true
  '';

  # A check sees its specification and the shared keymap module, so editing
  # one specification reruns only its own check.
  specifications =
    specification:
    lib.fileset.toSource {
      root = ../tests/bombadil;
      fileset = lib.fileset.unions [
        ../tests/bombadil/keymap.ts
        (../tests/bombadil + "/${specification}")
      ];
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
        --specification ${specifications specification}/${specification} \
        --output-path "$TMPDIR/trace" \
        -- ${lib.escapeShellArgs command} >"$TMPDIR/bombadil.log"; then
        ${violations}
        tail -n 80 "$TMPDIR/bombadil.log"
        echo "Trace: $TMPDIR/trace (rebuild with --keep-failed to keep it)"
        exit 1
      fi
      tail -n 3 "$TMPDIR/bombadil.log"
      touch "$out"
    '';

  # Explores the page at `origin` in headless Chromium for `timeLimit` and
  # fails on the first property violation. `setup` starts the server; any
  # other attribute, such as pnpmDeps, goes to the derivation.
  browserCheck =
    {
      name,
      specification,
      origin,
      timeLimit ? "2m",
      setup ? "",
      nativeBuildInputs ? [ ],
      ...
    }@args:
    pkgs.stdenvNoCC.mkDerivation (
      removeAttrs args [
        "specification"
        "origin"
        "timeLimit"
        "setup"
      ]
      // {
        name = "bombadil-${name}";
        nativeBuildInputs = nativeBuildInputs ++ [
          package
          pkgs.chromium
        ];
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME/.cache" "$HOME/.config" "$HOME/.local" "$HOME/.pki"
          export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache"
          export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = [ pkgs.freefont_ttf ]; }}
          # Bombadil's client for Chromium's debugger loads root certificates
          # and cannot start with the sandbox's placeholder file.
          export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
          export CHROME=${lib.getExe pkgs.chromium}
          ${setup}
          if ! bombadil browser test \
            --headless \
            --no-sandbox \
            --exit-on-violation \
            --time-limit ${timeLimit} \
            --output-path "$TMPDIR/trace" \
            ${lib.escapeShellArg origin} \
            ${specifications specification}/${specification} >"$TMPDIR/bombadil.log" 2>&1; then
            ${violations}
            tail -n 80 "$TMPDIR/bombadil.log"
            echo "Trace: $TMPDIR/trace (rebuild with --keep-failed to keep it)"
            exit 1
          fi
          tail -n 3 "$TMPDIR/bombadil.log"
          runHook postBuild
        '';
        installPhase = ''
          touch "$out"
        '';
      }
    );
}
