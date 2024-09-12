{ pkgs, lib, ... }: {
    nix.gc.automatic = true;
    nix.optimise.automatic = true;
    nix.settings.auto-optimise-store = true;
    environment.systemPackages =
      [ 
        pkgs.helix
        pkgs.zoxide
        pkgs.starship
        pkgs.stow
        pkgs.glow
        pkgs.tree
      ];
    environment.shells = [ pkgs.nushell ];
    environment.variables = {
      EDITOR = "hx";
    };
    fonts.packages = [ pkgs.monaspace ];


    environment.shellAliases = {
      dre = "darwin-rebuild edit";
      drs = "darwin-rebuild switch --flake ~/.config/home-manager";
    };
    services.nix-daemon.enable = true;

    nix.settings.experimental-features = "nix-command flakes";
    nix.settings.trusted-users = [
      "root"
      "tyschlichenmeyer"
    ];

    nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [
      "terraform"
      "vault"
    ];

    system.stateVersion = 4;
    system.keyboard = {
      enableKeyMapping = true; 
      remapCapsLockToEscape = true;
      swapLeftCtrlAndFn = true;
    };
    security.pam.enableSudoTouchIdAuth = true;
    system.defaults.screencapture.location = "/Users/tyschlichenmeyer/Downloads";
    system.defaults.dock = {
      orientation = "left";
    };

    nixpkgs.hostPlatform = "aarch64-darwin";
    users.users.tyschlichenmeyer = {
      name = "tyschlichenmeyer";
      home = "/Users/tyschlichenmeyer";
    };   
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
    programs.zsh.enable = true;  
    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = true;
    };
    services.sketchybar.enable = true;
    
    system.defaults.NSGlobalDomain = {
      AppleInterfaceStyleSwitchesAutomatically = true;
      AppleScrollerPagingBehavior = true;
      AppleShowScrollBars = "Always";
    };
 
}
