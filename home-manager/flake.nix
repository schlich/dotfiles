{
  description = "Home Manager configuration of nixos";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nushell-src = {
      url = "github:nushell/nushell";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nushell-src,
      ...
    }@inputs:
    let
      system = "x86_64-linux";
      overlays = [
        (final: prev: {
          nushell = prev.nushell.overrideAttrs (
            old:
            let
              crateMeta = builtins.fromTOML (builtins.readFile "${nushell-src}/Cargo.toml");
            in
            {
              src = nushell-src;
              version = crateMeta.package.version;
              cargoDeps = prev.rustPlatform.importCargoLock {
                lockFile = "${nushell-src}/Cargo.lock";
                outputHashes = {
                  "nu-ansi-term-0.50.2" = "sha256-ZZ4bHYQz7MGfgZ8vT+ixlpSBU7HIf5cCqcfsmgh2yVU=";
                  "reedline-0.42.0" = "sha256-UEvLeJVGlXvljfZuTlMuWrSnFbuiAwwdgQ7OukqM65s=";
                };
              };
              cargoBuildFeatures = prev.lib.unique ((old.cargoBuildFeatures or [ ]) ++ [ "mcp" ]);
            }
          );
        })
      ];
      pkgs = import nixpkgs {
        # inherit system;
        inherit system overlays;
      };
    in
    {
      overlays = overlays;

      # WSL configuration (current machine)
      homeConfigurations."nixos" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
        ];
      };

      # Native Linux configuration with niri (new machine)
      homeConfigurations."nixos-niri" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ./home.nix
          ./niri.nix
        ];
      };
    };
}
