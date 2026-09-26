{ inputs, pkgs, ... }:

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
  jevScript = pkgs.writeNuScriptBin "jev" (builtins.readFile ../../jev/jev.nu);
  jev = pkgs.symlinkJoin {
    name = "jev";
    paths = [ jevScript ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/jev" \
        --set-default JEV_QUESTIONS ${../../jev/questions.nuon} \
        --set-default JEV_SECRETSPEC_FILE ${../secretspec.toml} \
        --prefix PATH : ${pkgs.secretspec}/bin
    '';
  };
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
    secretspec
    jev
    inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default
    inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
