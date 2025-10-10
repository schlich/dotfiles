{ config, pkgs, ... }:

{
  home.username = "schlich";
  home.homeDirectory = "/home/schlich";
  home.stateVersion = "25.05";

  nixpkgs.config.allowUnfree = true;
  # xdg.portal = {
  #   enable = true;
  #   extraPortals = [ pkgs.xdg-desktop-portal-gnome pkgs.xdg-desktop-portal-gtk ];
  #   config.common.default = "*";
    
  # };
  # environment.pathsToLink = [ "/share/xdg-desktop-portal" "/share/applications" ];
 
  home.packages = with pkgs; [
    wget
    biome
    wslu
    nix-ld
    nixfmt-rfc-style
    systemctl-tui
    nil
    nixd
    nix-search-tv
    # xwayland-satellite
    eget
    difftastic
    chezmoi
    manix
    opencode
    taplo
    cargo
    rustc
    fx
    nix-search-tv
    fzf
    rerun
    blender
    deno
    firefox
    libgcc
    bun
    d2
    nodejs
    uv
    opencode

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/nixos/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    NIXPKGS_ALLOW_UNFREE = 1;
    # PATH for VS Code and non-login shells
    # This ensures tools like uv are available in VS Code's execution environment
  };

  # Ensure PATH is properly set for non-interactive shells
  home.sessionPath = [
    "$HOME/.nix-profile/bin"
    "/etc/profiles/per-user/$USER/bin"
  ];

  programs = {
    claude-code.enable = true;
    nix-search-tv = {
      enable = true;
      enableTelevisionIntegration = true;
    };
    codex.enable = true;
    htop.enable = true;
    home-manager.enable = true;
    ghostty.enable = true;
    gemini-cli.enable = true;
    yazi = {
      enable = true;
      enableNushellIntegration = true;
    };
    direnv = {
      enable = true;
      enableNushellIntegration = true;
      nix-direnv.enable = true;
    };
    nushell = {
      enable = true;
      configFile.source = ./config.nu;
      environmentVariables = {
        EDITOR = "${pkgs.helix}/bin/hx";
      };
    };
    zoxide = {
      enable = true;
      enableNushellIntegration = true;
    };
    carapace = {
      enable = true;
      enableNushellIntegration = true;
    };
    jujutsu = {
      enable = true;
      settings = {
        user = {
          email = "ty.schlich@gmail.com";
          name = "schlich";
        };
        ui = {
          diff-formatter = [
            "difft"
            "--color=always"
            "$left"
            "$right"
          ];
        };
      };
    };
    jjui.enable = true;
    atuin = {
      enable = true;
      enableNushellIntegration = true;
    };
    helix = {
      enable = true;
      extraPackages = with pkgs; [
        nixd
        nil
        nixfmt-rfc-style
        marksman
      ];
      defaultEditor = true;
      settings = {
        theme = "dracula";
        editor = {
          line-number = "relative";
        };
      };
    };
    # keychain = {
    #   enable = true;
    #   enableNushellIntegration = true;
    #   enableXsessionIntegration = true;
    # };
    claude-code.enable = true;
    zed-editor.enable = true;
    
  };
  # xsession = {
    # enable = true;
    # windowManager.command = ???
  # };
  # services = {
    # gpg-agent = {
      # enable = true;
      # enableSshSupport = true;
      # enableNushellIntegration = true;
      # sshKeys = [ "id_rsa" ];
    # };
    # lxqt-policykit-agent.enable = true;
  # };
  # wayland.windowManager.labwc = {
  #   enable = true;
  #   xwayland.enable = true;
  # }
}
