{ pkgs, ... }:

{
  home.packages = with pkgs; [
    xdg-user-dirs
    bubblewrap
    git
    wget
    nix-search-tv
    difftastic
    fzf
    glow
    bat
    systemctl-tui
    systemd-manager-tui
    dust
    wl-clipboard-rs
  ];
}
