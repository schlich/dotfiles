{ pkgs, ... }: 

{
    # List packages installed in system profile. To search by name, run:
    # $ nix-env -qaP | grep wget
    environment.systemPackages = [
        pkgs.nixd
    ];
    environment.shells = [ pkgs.nushell ];
    environment.loginShell = "/run/current-system/sw/bin/nu";
    fonts.packages = [ pkgs.monaspace pkgs.nerdfonts ];
    
    users.users.tyschlichenmeyer.shell = pkgs.nushell ;

    system.keyboard.enableKeyMapping = true;
    system.keyboard.remapCapsLockToEscape = true; 
    
    security.pam.enableSudoTouchIdAuth = true;
    # Auto upgrade nix package and the daemon service.
    services.nix-daemon.enable = true;
    services.jankyborders.enable = true;
    # services.karabiner-elements.enable = true;
    # nix.package = pkgs.nix;
    services.sketchybar.enable = true;

    # Necessary for using flakes on this system.
    nix.settings.experimental-features = "nix-command flakes";

    # Used for backwards compatibility, please read the changelog before changing.
    # $ darwin-rebuild changelog
    system.stateVersion = 4;

    # The platform the configuration will be used on.
    nixpkgs.hostPlatform = "aarch64-darwin";

    users.users.tyschlichenmeyer= {
        name = "tyschlichenmeyer";
        home = "/Users/tyschlichenmeyer";
    };
  }
