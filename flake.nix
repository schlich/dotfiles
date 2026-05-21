{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-wsl = {
      url = "github:nix-community/nixos-wsl";
    };
    nixgl.url = "github:nix-community/nixGL";
    nuenv.url = "https://flakehub.com/f/xav-ie/nuenv/*.tar.gz";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };
    marimo-pair.url = "github:schlich/marimo-pair";
    opencode = {
      url = "github:anomalyco/opencode";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    rust-docs-mcp = {
      url = "github:christian-blades-cb/rust-docs-mcp/2d69d7acd57a36456f844df45e8aade257352257";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    jj-starship = {
      url = "gitlab:lanastara_foss/starship-jj";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fh.url = "https://flakehub.com/f/DeterminateSystems/fh/*";
  };

  outputs =
    inputs@{
      flake-parts,
      home-manager,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      perSystem =
        { pkgs, system, ... }:
        {
          _module.args.pkgs = import nixpkgs {
            inherit system;
            overlays = [ inputs.jj-starship.overlays.default ];
            config.allowUnfree = true;
          };

          formatter = pkgs.nixfmt-tree;
        };

      flake =
        let
          mkNixos =
            modules:
            nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              specialArgs = { inherit inputs; };
              inherit modules;
            };

          pkgs = import nixpkgs {
            system = "x86_64-linux";
            overlays = [ inputs.jj-starship.overlays.default ];
            config.allowUnfree = true;
          };
        in
        {
          nixosConfigurations = {
            nixos = mkNixos [
              inputs.nixos-wsl.nixosModules.wsl
              # inputs.determinate.nixosModules.default
              inputs.agenix.nixosModules.default
              ./configuration.nix
            ];

            desktop = mkNixos [
              inputs.agenix.nixosModules.default
              ./system/hardware-configuration.nix
              ./system/configuration.nix
              (
                { pkgs, ... }:
                {
                  environment.systemPackages = [
                    inputs.fh.packages.${pkgs.stdenv.hostPlatform.system}.default
                    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
                  ];
                }
              )
            ];
          };

          homeConfigurations.schlich = home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              ./home.nix
              # ./noctalia.nix
              # inputs.niri.homeModules.niri
            ];
            extraSpecialArgs = {
              inherit inputs;
              # nixgl = inputs.nixgl;
            };
          };
        };
    };
}
