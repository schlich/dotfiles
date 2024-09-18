{
  description = "Darwin configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    darwin.url = "github:lnl7/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nufmt.url = "github:nushell/nufmt";
    nufmt.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = inputs@{ nixpkgs, home-manager, darwin, nufmt,  ... }: 
    let 
      system="aarch64-darwin";
      nufmt = nufmt.packages.${system};
      overlay = final: prev: { nufmt = nufmt.packages.${system}.nufmt; };
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ overlay ];
      };
    in {
    darwinConfigurations."Ty-Schlichenmeyer-MacBook-Air" = darwin.lib.darwinSystem {
      modules = [
        ./darwin-configuration.nix
        home-manager.darwinModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.tyschlichenmeyer = import ./home.nix;

        }
      ];
    };
  };
}
