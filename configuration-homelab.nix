{ ... }:

{
  imports = [
    ./modules/nixos/headless.nix
    ./modules/nixos/homelab.nix
    ./hosts/homelab
  ];
}
