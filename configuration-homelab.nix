{ ... }:

{
  imports = [
    ./modules/nixos/headless.nix
    ./modules/nixos/homelab.nix
    ./modules/nixos/tangled-spindle.nix
    ./hosts/homelab
  ];
}
