{ pkgs, ... }:

{
  users.defaultUserShell = pkgs.nushell;
  users.users.schlich = {
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
}
