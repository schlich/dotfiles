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
    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    clan-core = {
      url = "git+https://git.clan.lol/clan/clan-core";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fh.url = "https://flakehub.com/f/DeterminateSystems/fh/*.tar.gz";
    agent-skills = {
      url = "github:Kyure-A/agent-skills-nix";
      inputs.home-manager.follows = "home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    codex-desktop-linux.url = "github:ilysenko/codex-desktop-linux";
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
      self,
      home-manager,
      determinate,
      agent-skills,
      anthropic-skills,
      nixpkgs,
      fh,
      jj-starship,
      nixos-wsl,
      clan-core,
      nushellWith,
      ...
    }:
    let
      system = "x86_64-linux";
      username = "schlich";
      homeDirectory = "/home/${username}";
      stateVersion = "26.05";
      overlays = [
        jj-starship.overlays.default
        nushellWith.overlays.default
      ];
      pkgs = import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
      };
      lib = nixpkgs.lib;
      commonSpecialArgs = {
        inherit
          homeDirectory
          inputs
          stateVersion
          username
          ;
      };
      homeManagerModuleFor =
        {
          codexDesktopLinux ? false,
        }:
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = commonSpecialArgs // {
              inherit codexDesktopLinux;
            };
            users.${username} = import ./home.nix;
            backupFileExtension = "bak";
          };
          nixpkgs.overlays = overlays;
          environment.systemPackages = [
            fh.packages.x86_64-linux.default
            pkgs.jj-starship
          ];
        };
      homeManagerModule = homeManagerModuleFor { };
      clan = clan-core.lib.buildClan {
        inherit self;
        meta.name = "schlich-homelab";
        specialArgs = commonSpecialArgs;
        machines = {
          asus = {
            nixpkgs.hostPlatform = system;
            imports = [
              determinate.nixosModules.default
              home-manager.nixosModules.home-manager
              inputs.noctalia-greeter.nixosModules.default
              inputs.niri.nixosModules.niri
              ./configuration.nix
              ./hosts/asus/storage-internal.nix
              (homeManagerModuleFor { codexDesktopLinux = true; })
            ];
          };
          asus-usb = {
            nixpkgs.hostPlatform = system;
            imports = [
              determinate.nixosModules.default
              home-manager.nixosModules.home-manager
              inputs.noctalia-greeter.nixosModules.default
              inputs.niri.nixosModules.niri
              ./configuration.nix
              ./hosts/asus/hardware-configuration.nix
              homeManagerModule
            ];
          };
          homelab = {
            nixpkgs.hostPlatform = system;
            imports = [
              determinate.nixosModules.default
              home-manager.nixosModules.home-manager
              ./modules/nixos/base.nix
              ./modules/nixos/core.nix
              ./modules/nixos/headless.nix
              ./modules/nixos/files.nix
              ./modules/nixos/user.nix
              ./hosts/homelab/default.nix
              homeManagerModule
            ];
          };
        };
      };
      nixosConfigurations = clan.nixosConfigurations // {
        nixos-wsl = lib.nixosSystem {
          inherit system;
          specialArgs = commonSpecialArgs;
          modules = [
            determinate.nixosModules.default
            nixos-wsl.nixosModules.default
            home-manager.nixosModules.home-manager
            ./hosts/wsl
            homeManagerModule
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
      inherit (clan) clanInternals;

      clan = {
        inherit (clan) templates;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ clan-core.packages.${system}.clan-cli ];
      };

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
