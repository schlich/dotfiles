{
  description = "Darwin configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    darwin.url = "github:lnl7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
    # home-manager.url = "github:nix-community/home-manager";
    # home-manager.inputs.nixpkgs.follows = "nixpkgs";
  };
    outputs = inputs@{ nixpkgs, darwin, ... }: 
    { 
      darwinConfigurations."Ty-Schlichenmeyer-MacBook-Air" = darwin.lib.darwinSystem {
        modules = [
          ./darwin-configuration.nix
          # home-manager.darwinModules.home-manager
          # {
          #   home-manager.useGlobalPkgs = true;
          #   home-manager.useUserPackages = true;
          #   home-manager.users.tyschlichenmeyer = import ./home.nix;

          # }
        ];
      };
    };
}
