{ lib, pkgs, ... }:

{
  users.defaultUserShell = pkgs.nushell;
  users.users.schlich = {
    # asus's UID; a host whose account predates this declaration sets its own.
    uid = lib.mkDefault 1001;
    shell = pkgs.nushell;
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
  };
  environment.shells = [ pkgs.nushell ];
  # Nushell searches share/nushell/vendor/autoload in the system and per-user
  # profiles through XDG_DATA_DIRS; Home Manager ships its autoload files
  # there instead of ~/.config/nushell/autoload.
  environment.pathsToLink = [ "/share/nushell" ];

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
      AllowUsers = [ "schlich" ];
    };
  };
}
