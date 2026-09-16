{ pkgs, lib, ... }:

{
  den.schema.user.classes = lib.mkDefault [ "user" ];
  den.hosts.asus = {
    system = "x86_64-linux";
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
