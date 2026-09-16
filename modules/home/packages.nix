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
in
{
  home.packages = with pkgs; [
    (callPackage ./openchamber.nix { })
    xdg-user-dirs
    bubblewrap
    acreomApp
    super-productivity
    zotero
    marimo
    nodejs
    ty
    git
    wget
    nixfmt
    ruff
    systemctl-tui
    systemd-manager-tui
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
    inputs.xs.packages.${pkgs.system}.default
    inputs.ai-usagebar.packages.${pkgs.system}.default
  ];
}
