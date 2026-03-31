{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    fh.url = "https://flakehub.com/f/DeterminateSystems/fh/*";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
    };
    nixgl.url = "github:nix-community/nixGL";
    nuenv.url = "https://flakehub.com/f/xav-ie/nuenv/*.tar.gz";
    nix-inspect.url = "github:bluskript/nix-inspect";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-docs-mcp = {
      url = "github:christian-blades-cb/rust-docs-mcp/2d69d7acd57a36456f844df45e8aade257352257";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nixos-wsl,
      determinate,
      fh,
      nixgl,
      nuenv,
      nix-inspect,
      ...
    }@inputs:
    {
      nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
        specialArgs = { inherit inputs; };
        modules = [
          nixos-wsl.nixosModules.wsl
          determinate.nixosModules.default
          {
            nix.nixPath = [ "nixpkgs=${inputs.nixpkgs}" ];
            environment.systemPackages = [
              fh.packages.x86_64-linux.default
              nix-inspect.packages.x86_64-linux.default
            ];
            nixpkgs = {
              system = "x86_64-linux";
            };
            programs.nix-ld.enable = true;
          }
          ./configuration.nix
        ];
      };
      homeConfigurations.schlich = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [ ./home.nix ];
        extraSpecialArgs = { inherit inputs nixgl; };
      };
      formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt-tree;

    };
}
