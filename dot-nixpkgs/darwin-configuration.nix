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
        NSGlobalDomain = {
          AppleInterfaceStyleSwitchesAutomatically = true;
          AppleScrollerPagingBehavior = true;
          AppleShowScrollBars = "Always";
        };
      };
    };

    security.pam.enableSudoTouchIdAuth = true;

    environment = {
      systemPackages = with pkgs; [
        helix
        python313
        tre-command
        ncdu
        nodenv
        robotframework-tidy
        watchexec
        fzf
        fd
        ripgrep
        yazi
        stow
        glow
        nushell
        nixd
        bat
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
        aichat
        xq-xml
        taplo
        rustup
        dockerfile-language-server-nodejs
        vscode-langservers-extracted
        tinymist
        chezmoi
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
