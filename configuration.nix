{ inputs, ... }:

{
  imports = [
    inputs.noctalia.nixosModules.default
    ./modules/nixos
    ./hosts/asus
  ];
}
