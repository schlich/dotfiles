{ den, ... }:

{
  imports = [
    ./schema.nix
    ./policy.nix
    ./inventory.nix
    ./aspects/base.nix
    ./aspects/host-profile.nix
    ./aspects/workstation.nix
    ./aspects/server.nix
    ./aspects/system-files.nix
    ./aspects/wsl.nix
    ./aspects/desktop-niri.nix
    ./aspects/input-stack.nix
    ./aspects/laptop.nix
    ./aspects/development.nix
    ./aspects/homelab.nix
    ./aspects/remote.nix
    ./aspects/secrets.nix
    ./aspects/gpu-amd.nix
    ./aspects/xr.nix
    ./aspects/users/terminal.nix
    ./aspects/users/packages.nix
    ./aspects/users/schlich.nix
    ./aspects/host-platforms.nix
    ./hosts.nix
  ];

  den.default = {
    includes = [
      den.aspects.base
      den.aspects.system-files
    ];
  };
}
