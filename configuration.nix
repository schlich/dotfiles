{ pkgs, inputs, ... }:
{
  nixpkgs.hostPlatform = "x86_64-linux";
  time.hardwareClockInLocalTime = true;
  users.defaultUserShell = pkgs.nushell;
  users.users.nixos.shell = pkgs.nushell;

  wsl = {
    enable = true;
    defaultUser = "nixos";
    useWindowsDriver = true;
    ssh-agent.enable = true;
    startMenuLaunchers = true;
  };

  environment = {
    shells = [ pkgs.nushell ];
    variables = {
      EDITOR = "hx";
      VISUAL = "hx";
      LD_LIBRARY_PATH = "/usr/lib/wsl/lib";
    };
    systemPackages = [
      pkgs.wget
      inputs.ragenix.packages.x86_64-linux.default
    ];
  };

  age.secrets.github-token = {
    file = ./secrets/github-token.age;
    owner = "nixos";
    mode = "0400";
  };
  age.identityPaths = [ "/home/nixos/.ssh/id_ed25519" ];

  system.stateVersion = "26.05";

  services.dbus.implementation = "broker";
  programs = {
    nix-ld.enable = true;
    niri.enable = true;
  };

}
