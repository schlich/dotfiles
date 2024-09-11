{ pkgs, ... }: {
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


    services.nix-daemon.enable = true;

    nix.settings.experimental-features = "nix-command flakes";
    nix.settings.trusted-users = [
      "root"
      "tyschlichenmeyer"
    ];

    # programs.zsh.enable = true;  # default shell on catalina

    system.stateVersion = 4;
    system.keyboard = {
      enableKeyMapping = true; 
      remapCapsLockToEscape = true;
    };

    nixpkgs.hostPlatform = "aarch64-darwin";
    users.users.tyschlichenmeyer = {
      name = "tyschlichenmeyer";
      home = "/Users/tyschlichenmeyer";
    };   
 
}
