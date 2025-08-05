# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

# NixOS-WSL specific options are documented on the NixOS-WSL repository:
# https://github.com/nix-community/NixOS-WSL

{ config, lib, pkgs, ... }:

{
  imports = [
    # include NixOS-WSL modules
    <nixos-wsl/modules>
  ];

  wsl.enable = true;
  wsl.docker-desktop.enable = true;
  nixpkgs.config.allowUnfree = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "24.11"; # Did you read the comment?
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.sessionVariables = {
    EDITOR = "hx";
    SHELL = "nu";
    PKG_CONFIG_PATH = "${pkgs.openssl.dev}/lib/pkgconfig";
  };
  environment.systemPackages = with pkgs; [
    atuin
    nerd-fonts.monaspace
    ffmpeg
    yazi
    yaziPlugins.bypass
    yaziPlugins.chmod
    yaziPlugins.duckdb
    yaziPlugins.git
    yaziPlugins.glow
    yaziPlugins.lazygit
    yaziPlugins.mime-ext
    yaziPlugins.rich-preview
    yaziPlugins.smart-enter
    yaziPlugins.smart-filter
    yaziPlugins.starship
    yaziPlugins.sudo
    yaziPlugins.toggle-pane
    yaziPlugins.wl-clipboard
    gzip
    jq
    poppler
    vscode-css-languageserver
    superhtml
    vscode-json-languageserver
    dot-language-server
    yaml-language-server
    tinymist
    taplo
    typescript-language-server
    basedpyright
    nixd
    marksman
    just-lsp
    lazygit
    zellij
    mise
    mprocs
    chezmoi
    wget
    clipse
    nushell
    helix
    starship
    devcontainer
    bat
    gh
    zoxide
    uv
    ruff
    blas
    google-cloud-sdk
    lazygit
    jujutsu
    lazyjj
    typst
    nodejs
    cargo
    rustc
    pkg-config
    ghostty
    kitty
    wslu
    gcc
    markdown-oxide
    just
    busybox
    glamoroustoolkit
    direnv
    nil
    pass
    sudo-rs
    carapace
    claude-code
    opencode
    fzf
    resvg
    openssl
    graphite-cli
    gemini-cli
    devbox
  ];
  programs = {
    nix-ld.enable = true;
    git.enable = true;
    gnupg = {
      agent = {
        enable = true;
        enableBrowserSocket = true;
        enableExtraSocket = true;
        enableSSHSupport = true;
        # pinentryPackage = pkgs.pinentry-gnome3;
      };
    };
  };
  nix.settings = {
    extra-substituters = [ "https://yazi.cachix.org" ];
    extra-trusted-public-keys = [ "yazi.cachix.org-1:Dcdz63NZKfvUCbDGngQDAZq6kOroIrFoyO064uvLh8k=" ];
  };
}
