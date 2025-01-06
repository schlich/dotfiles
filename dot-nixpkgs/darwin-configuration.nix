{ pkgs, lib, ... }: {

    nix = {
      settings.experimental-features = "nix-command flakes";

      gc.automatic = true;
      optimise.automatic = true;
      settings.trusted-users = [
        "root"
        "tyschlichenmeyer"
      ];
    };


    system = {
      stateVersion = 4;
      keyboard = {
        enableKeyMapping = true; 
        remapCapsLockToEscape = true;
        swapLeftCtrlAndFn = false;
      };
      defaults = {
        screencapture.location = "/Users/tyschlichenmeyer/Downloads";
        dock = {
          orientation = "left";
          autohide = true;
        };
        NSGlobalDomain = {
          AppleInterfaceStyleSwitchesAutomatically = true;
          AppleScrollerPagingBehavior = true;
          AppleShowScrollBars = "Always";
        };
      };
    };

    security.pam.enableSudoTouchIdAuth = true;

    # home-manager.backupFileExtension = "bak";

    environment = {
      systemPackages = with pkgs; [ 
        python310
        tre-command
        dust
        nodenv
        robotframework-tidy
        watchexec
        fzf
        fd
        ripgrep
        yazi
        helix
        stow
        glow
        mdcat
        tree
        nushell
        nixd
        bat
        kitty
        zoxide
        direnv
        starship
        just
        lazygit
        poetry
        ruff
        basedpyright
        yaml-language-server
        ansible-language-server
        tealdeer
        gh
        gh-dash
        fx
        # vault
        marksman
        carapace
        heroku
        aichat
        xq-xml
      ];
      pathsToLink = [
        "/share"
        "/bin"
        "/Applications"
      ];
      systemPath = [
        "/run/current-system/sw/bin"
        "/usr/local/bin"
      ];
      shells = [ pkgs.nushell ];
      variables = {
        EDITOR = "hx";
      };
      shellAliases = {
        dre = "darwin-rebuild -I ~/dotfiles/dot-nixpkgs";
        drs = "darwin-rebuild switch --flake ~/dotfiles/dot-nixpkgs";
      };
   };

    nixpkgs = {
      config.allowUnfreePredicate = pkg:
        builtins.elem (lib.getName pkg) [
          "terraform"
          "vault"
      ];
      hostPlatform = "aarch64-darwin";
    };

    fonts.packages = [ pkgs.monaspace ];

    users.users.tyschlichenmeyer = {
      name = "tyschlichenmeyer";
      home = "/Users/tyschlichenmeyer";
      shell = pkgs.nushell;
    };   

    programs = {
      direnv = {
        enable = true;
      };
      gnupg.agent = {
        enable = true;
        enableSSHSupport = true;
      };
    };

    services = {
      sketchybar.enable = true;
      nix-daemon.enable = true;
    };
   
}
