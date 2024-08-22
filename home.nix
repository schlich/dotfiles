{ pkgs, ... }:

{
  # home.username = "tyschlichenmeyer";
  # home.homeDirectory = "/Users/tyschlichenmeyer";
  # targets.darwin.defaults.NSGlobalDomain.AppleLocale = "en_US";

  home.stateVersion = "23.05";

  home.packages = with pkgs; [
    nixd
    jira-cli-go
    pijul
    pyright
    pylyzer
    lua
    yaml-language-server
    glow
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })
 ];

  home.file = {
    # "$env.XDG_CONFIG_HOME/nushell/nupm".source = /Users/tyschlichenmeyer/.config/nushell/nupm;
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

 
  programs.home-manager.enable = true;
  # programs.direnv = {
  #   enable = true;
  #   enableNushellIntegration = true;
  #   nix-direnv.enable = true;
  # };
  programs.nushell = {
    enable = true;
    shellAliases = {
      pj = "pijul";
      gst = "git status";
      hme = "home-manager edit";
      hms = "home-manager switch";
      lg = "lazygit";
    };
    environmentVariables = {
      EDITOR = "hx";
      XDG_CACHE_HOME = "/Users/tyschlichenmeyer/.cache";
      XDG_CONFIG_HOME = "/Users/tyschlichenmeyer/.config";
      XDG_DATA_HOME = "/Users/tyschlichenmeyer/.local/share";
      XDG_STATE_HOME = "/Users/tyschlichenmeyer/.local/state";
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
  programs.helix.enable = true;
  programs.fzf.enable = true;
  home.preferXdgDirectories = true;
  xdg.enable = true;

}
