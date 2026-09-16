{ pkgs, lib, ... }:

{
  den.schema.user.classes = lib.mkDefault [ "user" ];
  den.hosts.x86_64-linux.asus = {
    users.schlich = {
      uid = 1001;
      shell = pkgs.nushell;
      isNormalUser = true;
      extraGroups = [
        "wheel"
        "networkmanager"
      ];
    };

  };
}
