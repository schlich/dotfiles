{ pkgs, inputs, ... }:
{
  # WSL-specific configuration
  wsl.enable = true;
  wsl.defaultUser = "nixos";

  environment.systemPackages = [
    pkgs.wget
  ];

  system.stateVersion = "23.11";

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  programs.nix-ld.enable = true;

  services.xserver = {
    xkb = {
      layout = "us,gr";
      options = "grp:rctrl_switch";
    };
  };
}
