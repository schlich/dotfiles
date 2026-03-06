{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable"; # Unstable for niri features
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
    in
    {
      nixosConfigurations = {
        wsl = nixpkgs.lib.nixosSystem {
          inherit system specialArgs;
          modules = [
            nixos-wsl.nixosModules.wsl
            ./hosts/wsl/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.nixos = import ./home/wsl.nix;
              home-manager.extraSpecialArgs = specialArgs;
            }
          ];
        };

        desktop = nixpkgs.lib.nixosSystem {
          inherit system specialArgs;
          modules = [
            ./hosts/desktop/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              home-manager.users.nixos = import ./home/desktop.nix;
              home-manager.extraSpecialArgs = specialArgs;
            }
          ];
        };
      };

      # Standalone home-manager configuration (for non-NixOS or direct HM use)
      # homeConfigurations."nixos" = home-manager.lib.homeManagerConfiguration {
      #   pkgs = nixpkgs.legacyPackages.${system};
      #   extraSpecialArgs = specialArgs;
      #   modules = [ ./home/default.nix ];
      # };
    };
}
