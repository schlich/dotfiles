{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nushellWith.url = "github:YPares/nushellWith/master";
    marimo-pair = {
      url = "github:marimo-team/marimo-pair";
      flake = false;
    };
    marimo-skills = {
      url = "github:marimo-team/skills";
      flake = false;
    };
    gh-stack = {
      url = "github:github/gh-stack";
      flake = false;
    };
    grill-me = {
      url = "github:udecode/plate";
      flake = false;
    };
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };
    jj-starship = {
      url = "github:dmmulroy/jj-starship";
    };
    niri = {
      url = "github:epireyn/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia/cachix";
    };
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fh.url = "https://flakehub.com/f/DeterminateSystems/fh/*.tar.gz";
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.home-manager.follows = "home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    anthropic-skills = {
      url = "github:anthropics/skills";
      flake = false;
    };
    modern-web-guidance = {
      url = "github:GoogleChrome/modern-web-guidance";
      flake = false;
    };
    archify = {
      url = "github:tt-a1i/archify";
      flake = false;
    };
    meta-quest-agentic-tools = {
      url = "github:meta-quest/agentic-tools";
      flake = false;
    };
  };

  outputs =
    inputs@{
      home-manager,
      determinate,
      agent-skills,
      anthropic-skills,
      nixpkgs,
      fh,
      jj-starship,
      nushellWith,
      ...
    }:
    let
      system = "x86_64-linux";
      overlays = [
        jj-starship.overlays.default
        nushellWith.overlays.default
      ];
      pkgs = import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
      };
      lib = nixpkgs.lib;
      nixosConfigurations = {
        asus = lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            determinate.nixosModules.default
            home-manager.nixosModules.home-manager
            inputs.noctalia-greeter.nixosModules.default
            inputs.niri.nixosModules.niri
            ./configuration.nix
            ./hosts/asus/storage-internal.nix
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit inputs;
                  username = "schlich";
                  homeDirectory = "/home/schlich";
                  stateVersion = "26.05";
                };
                users.schlich = import ./home.nix;
              };
              nixpkgs.overlays = overlays;
              environment.systemPackages = [
                fh.packages.x86_64-linux.default
                pkgs.jj-starship
              ];
            }
          ];
        };
        asus-usb = lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = [
            determinate.nixosModules.default
            home-manager.nixosModules.home-manager
            inputs.noctalia-greeter.nixosModules.default
            inputs.niri.nixosModules.niri
            ./configuration.nix
            ./hosts/asus/hardware-configuration.nix
            {
              home-manager = {
                useGlobalPkgs = true;
                useUserPackages = true;
                extraSpecialArgs = {
                  inherit inputs;
                  username = "schlich";
                  homeDirectory = "/home/schlich";
                  stateVersion = "26.05";
                };
                users.schlich = import ./home.nix;
              };
              nixpkgs.overlays = overlays;
              environment.systemPackages = [
                fh.packages.x86_64-linux.default
                pkgs.jj-starship
              ];
            }
          ];
        };
      };

      homeCheck = pkgs.linkFarm "home-manager-check" (
        [
          {
            name = "activation";
            path = nixosConfigurations.asus.config.home-manager.users.schlich.home.activationPackage;
          }
        ]
        ++ lib.mapAttrsToList (checkName: path: {
          name = checkName;
          inherit path;
        }) nixosConfigurations.asus.config.home-manager.users.schlich.dotfiles.tooling.checks
      );
    in
    {
      inherit nixosConfigurations;

      templates.default = {
        path = ./templates/default;
        description = "Nushell and Jujutsu project starter";
        welcomeText = ''
          # Project initialized

          Run `direnv allow` or `nix develop`, then replace the placeholder
          project metadata and add the language-specific tools you need.
        '';
      };

      packages.${system} = {
        default = nixosConfigurations.asus.config.system.build.toplevel;
      };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = {
        home-manager-nixos = homeCheck;
        niri-config =
          pkgs.runCommand "niri-config-check"
            {
              nativeBuildInputs = [ pkgs.niri ];
            }
            ''
              niri validate --config ${./niri/config.kdl}
              touch "$out"
            '';
        zellij-config =
          pkgs.runCommand "zellij-config-check"
            {
              nativeBuildInputs = [ pkgs.zellij ];
            }
            ''
              config_dir="$TMPDIR/zellij"
              mkdir -p "$config_dir/layouts"
              cp ${./zellij/config.kdl} "$config_dir/config.kdl"
              cp ${./zellij/layouts/default.kdl} "$config_dir/layouts/default.kdl"
              ZELLIJ_CONFIG_DIR="$config_dir" zellij setup --check
              touch "$out"
            '';
      };
    };
  nixConfig = {
    extra-substituters = [
      "https://noctalia.cachix.org"
    ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
    trusted-users = [ "schlich" ];
  };
}
