{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixgl.url = "github:nix-community/nixGL";
    nuenv.url = "https://flakehub.com/f/xav-ie/nuenv/*.tar.gz";
    ragenix = {
      url = "github:yaxitech/ragenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    marimo-pair.url = "github:schlich/marimo-pair";
    jj-starship = {
      url = "gitlab:lanastara_foss/starship-jj";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia/cachix";
    };
    fh.url = "https://flakehub.com/f/DeterminateSystems/fh/*";
  };

  outputs =
    inputs@{
      home-manager,
      nixpkgs,
      ...
    }:
    let
      system = "x86_64-linux";
      overlays = [
        inputs.jj-starship.overlays.default
        inputs.nuenv.overlays.default
      ];
      pkgs = import nixpkgs {
        inherit system;
        inherit overlays;
        config.allowUnfree = true;
      };
      lib = nixpkgs.lib;

      mkNixos =
        modules:
        lib.nixosSystem {
          inherit system modules;
          specialArgs = { inherit inputs; };
        };

      nixosConfigurations = {
        asus = mkNixos [
          inputs.determinate.nixosModules.default
          # inputs.ragenix.nixosModules.default
          ./configuration.nix
        ];
      };

      homeConfigurations.schlich = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
        ];
        extraSpecialArgs = {
          inherit inputs;
          username = "schlich";
          homeDirectory = "/home/schlich";
          stateVersion = "26.05";
        };
      };
    in
    {
      inherit nixosConfigurations homeConfigurations;

      formatter.${system} = pkgs.nixfmt-tree;

      devShells.${system} = {
        reedline = pkgs.mkShell {
          name = "reedline-dev";
          packages =
            with pkgs;
            [
              cargo-nextest
              clippy
              cargo
              git
              pkg-config
              rust-analyzer
              rustc
              rustfmt
              sqlite
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux [
              libxkbcommon
              wayland
            ];
        };
      };

      checks.${system} = {
        home-manager-nixos = homeConfigurations.schlich.activationPackage;
        asus = nixosConfigurations.asus.config.system.build.toplevel;
      };
    };
  nixConfig = {
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [ "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=" ];
    trusted-users = [ "schlich" ];
  };
}
