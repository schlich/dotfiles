{ pkgs, inputs, ... }:

{
  home.packages = with pkgs; [
    wget
    nixfmt
    systemctl-tui
    nix-search-tv
    difftastic
    fzf
    lsp-ai
    github-copilot-cli
    eget
    pixi
    uv
    glow
    bat
    gcc
    pipewire
    wireplumber
    inputs.ragenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
