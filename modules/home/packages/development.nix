{ inputs, pkgs, ... }:

{
  home.packages = with pkgs; [
    marimo
    nodejs
    ty
    nixfmt
    ruff
    pixi
    uv
    gcc
    nil
    nixd
    vscode-json-languageserver
    jj-starship
    dhall
    pandoc
    prek
    ripgrep
    gh-stack
    secretspec
    fx
    diffedit3
    inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
