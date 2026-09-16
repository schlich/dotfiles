{ den, ... }:
{
  den.aspects.schlich = {
    includes = [
      den.batteries.define-user
      den.aspects.user-terminal
    ];
    nixos =
      { pkgs, ... }:
      {
        users.users.schlich = {
          uid = 1001;
          shell = pkgs.nushell;
          isNormalUser = true;
          extraGroups = [
            "wheel"
            "networkmanager"
          ];
        };

        environment.shells = [ pkgs.nushell ];

        services.openssh = {
          enable = true;
          settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            PermitRootLogin = "no";
            AllowUsers = [ "schlich" ];
          };
        };
      };
    homeManager = {
      home.username = "schlich";
      home.homeDirectory = "/home/schlich";
      home.stateVersion = "26.05";
      dotfiles.primary = {
        terminal = "ghostty";
        editor = "helix";
        ai = "opencode";
      };
    };
  };
}
