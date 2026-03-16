{ pkgs, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  wsl = {
    enable = true;
    defaultUser = "schlich";
    useWindowsDriver = true;
    # extraBin = [
    #   {
    #     name = "xdg-open";
    #     copy = true;
    #     src = pkgs.writeShellScript "xdg-open" ''
    #       exec /mnt/c/Windows/System32/cmd.exe /c start "" "$@"
    #     '';
    #   }

    # ];
  };
  users.defaultUserShell = pkgs.nushell;
  environment = {
    shells = [ pkgs.nushell ];
    systemPackages = [
      pkgs.wget
    ];
    # sessionVariables = {
    #   LD_LIBRARY_PATH = [
    #     "/run/opengl-driver/lib"
    #     "/run/opengl-driver-32/lib"
    #     "${pkgs.openssl.out}/lib"
    #   ];
    #   GALLIUM_DRIVER = "d3d12";
    #   MESA_D3D12_DEFAULT_ADAPTER_NAME = "Intel";
    #   XCURSOR_THEME = "Adwaita";
    #   XCURSOR_SIZE = "24";
    # };
  };
  system.stateVersion = "26.05";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ mesa ];
    enable32Bit = true;
  };
}
