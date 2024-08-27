{ pkgs, ... }:

{
  # home.username = "tyschlichenmeyer";
  # home.homeDirectory = "/Users/tyschlichenmeyer";
  # targets.darwin.defaults.NSGlobalDomain.AppleLocale = "en_US";

  home.stateVersion = "23.05";

  home.packages = [
    pkgs.jira-cli-go
    pkgs.pijul
    pkgs.pyright
    pkgs.lua
    pkgs.glow
    pkgs.vault
    pkgs.python311
    pkgs.uv
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })
 ];

  home.file = {
    ".config/zellij".source = ./zellij;
    # "$env.XDG_CONFIG_HOME/nushell/nupm".source = /Users/tyschlichenmeyer/.config/nushell/nupm;
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

 
  programs.home-manager.enable = true;
  programs.nushell = {
    enable = true;
    shellAliases = {
      pj = "pijul";
      gst = "git status";
      ga = "git add";
      gcm = "git commit -m";
      gacm = "git commit -am";
      gd = "git diff";
      gp = "git pull";
      gP = "git push";
      hme = "home-manager edit";
      hms = "home-manager switch";
      lg = "lazygit";
      nrb = "darwin-rebuild switch --flake ~/dotfiles"; # "nix rebuild"
      zu = "zellij -l all"; # "zellij up"
      df = "enter ~/dotfiles";
    };
    configFile.source = ./nushell/config.nu;
    envFile.source = ./nushell/env.nu;
 };
  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      aws.disabled = true;
      nodejs.disabled = true;
      package.disabled = true;
      python.disabled = true;
      git_metrics.disabled = false;
      git_status.disabled = true;
      nix_shell.disabled = true;
      pijul_channel.disabled = false;
    };
  };
  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
  };
  programs.lazygit = {
    enable = true;
  };
  programs.bat.enable = true;
  programs.zoxide = {
    enable = true;
    enableNushellIntegration = true;
  };
  # programs.wezterm.enable = true;
  programs.carapace = {
    enable = true;
    enableNushellIntegration = true;
  };
  programs.keychain = {
    enable = true;
    enableNushellIntegration = true;
  };
  programs.zellij = {
    enable = true;
  };
  programs.ruff = {
    enable = true;
    settings = {};
  };
  programs.poetry.enable = true;
  programs.gh.enable = true;
  programs.gh-dash.enable = true;
  programs.navi.enable = true;
  programs.helix = {
    enable = true;
    # note: defaultEditor not working for nushell?
    defaultEditor = true;
    extraPackages = [
      pkgs.nixd
      pkgs.marksman
      pkgs.pylyzer
      pkgs.yaml-language-server
    ];
  };
  programs.fzf.enable = true;
  home.preferXdgDirectories = true;
  xdg.enable = true;
}
