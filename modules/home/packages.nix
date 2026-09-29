{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  acreomApp =
    let
      pname = "acreom";
      version = "1.20.3";
      src = pkgs.fetchurl {
        url = "https://github.com/Acreom/app/releases/download/v${version}/acreom-${version}.AppImage";
        hash = "sha256-pIUZGkMw0ghn8SDkZIo6SjNRdadZ+hAiEBmrckEgXoQ=";
      };
      appimageContents = pkgs.appimageTools.extract { inherit pname version src; };
    in
    pkgs.appimageTools.wrapType2 {
      inherit pname version src;

      extraInstallCommands = ''
        install -Dm444 ${appimageContents}/acreom.desktop -t $out/share/applications/
        install -Dm444 ${appimageContents}/acreom.png -t $out/share/icons/hicolor/512x512/apps/
        substituteInPlace $out/share/applications/acreom.desktop \
          --replace-fail 'Exec=AppRun --no-sandbox %U' 'Exec=acreom --no-sandbox %U'
      '';

      meta = {
        description = "A local-first knowledge base for developers";
        homepage = "https://acreom.com";
        changelog = "https://github.com/Acreom/app/releases/tag/v${version}";
        license = pkgs.lib.licenses.gpl3Only;
        mainProgram = pname;
        platforms = [ "x86_64-linux" ];
      };
    };
  handyApp =
    let
      pname = "handy";
      version = "0.9.6";
      src = pkgs.fetchurl {
        url = "https://github.com/cjpais/Handy/releases/download/v${version}/Handy_${version}_amd64.AppImage";
        hash = "sha256-xlL2lXLMhGMC12B2GYoHtNYrX3tUgoWTNSdYSjxi9P0=";
      };
      appimageContents = pkgs.appimageTools.extract { inherit pname version src; };
    in
    pkgs.appimageTools.wrapType2 {
      inherit pname version src;

      extraInstallCommands = ''
        install -Dm444 ${appimageContents}/Handy.desktop -t $out/share/applications/
        icon=$(find ${appimageContents} -type f \( -iname 'Handy.png' -o -iname 'handy.png' \) -print -quit)
        if test -n "$icon"; then
          install -Dm444 "$icon" $out/share/icons/hicolor/512x512/apps/handy.png
        fi
      '';

      meta = {
        description = "Privacy-focused speech-to-text application";
        homepage = "https://github.com/cjpais/Handy";
        changelog = "https://github.com/cjpais/Handy/releases/tag/v${version}";
        license = pkgs.lib.licenses.mit;
        mainProgram = pname;
        platforms = [ "x86_64-linux" ];
      };
    };
  jev = import ../../jev/package.nix { inherit pkgs; };
  # Opens a URL in Quest Browser over ADB. A localhost URL is reverse-forwarded
  # so the headset reaches this machine's port without an IP address.
  questOpen = pkgs.writeNuScriptBin "quest-open" ''
    def main [url: string = "https://localhost:8081/"] {
      let adb = "${pkgs.android-tools}/bin/adb"
      let devices = (^$adb devices | lines | skip 1 | where $it =~ '\tdevice$')
      if ($devices | is-empty) {
        error make {msg: "No headset is connected over ADB. Enable developer mode, connect it by USB, and accept the debugging prompt in the headset."}
      }
      let parsed = ($url | url parse)
      if $parsed.host in ["localhost" "127.0.0.1"] {
        let port = if ($parsed.port | is-empty) { if $parsed.scheme == "https" { "443" } else { "80" } } else { $parsed.port }
        ^$adb reverse $"tcp:($port)" $"tcp:($port)"
      }
      ^$adb shell am start -a android.intent.action.VIEW -d $url com.oculus.browser
    }
  '';
in
{
  home.packages = with pkgs; [
    (callPackage ./openchamber.nix { })
    xdg-user-dirs
    bubblewrap
    acreomApp
    handyApp
    super-productivity
    element-desktop
    discord
    zotero
    marimo
    nodejs
    ty
    git
    wget
    nixfmt
    nh
    nix-tree
    nix-du
    nix-output-monitor
    graphviz
    ruff
    systemctl-tui
    systemd-manager-tui
    mission-center
    nix-search-tv
    difftastic
    fzf
    lsp-ai
    pixi
    uv
    glow
    bat
    gcc
    nil
    nixd
    swaylock
    pavucontrol
    vscode-json-languageserver
    jj-starship
    xwayland-satellite
    dhall
    skills
    gcr_4
    clipboard-jh
    diffedit3
    dust
    font-awesome
    fx
    monaspace
    nerd-font-patcher
    nerd-fonts.symbols-only
    pandoc
    prek
    ripgrep
    wl-clipboard-rs
    gh-stack
    # The repository's wrappers depend on secretspec; keep this copy ahead of
    # the one devenv bundles so PATH does not follow devenv's release cadence.
    (lib.hiPrio secretspec)
    devenv
    jev
    questOpen
    inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.tangled-dash.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
