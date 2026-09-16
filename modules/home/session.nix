{ pkgs, ... }:

{
  home.sessionVariables = {
    SHELL = "${pkgs.nushell}/bin/nu";
    NIXOS_OZONE_WL = "1";
  };
}
