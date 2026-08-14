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
    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    grill-me = {
      url = "github:udecode/plate";
      flake = false;
    };
    jj-starship = {
      url = "github:dmmulroy/jj-starship";
    };
    niri = {
      url = "github:sodiboo/niri-flake";
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
    agent-skills.url = "github:Kyure-A/agent-skills-nix";
    anthropic-skills = {
      url = "github:anthropics/skills";
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
      codex-desktop-linux,
      ...
    }:
    let
      system = "x86_64-linux";
      overlays = [
        (final: prev: {
          github-copilot-cli = prev.github-copilot-cli.overrideAttrs (old: rec {
            version = "1.0.73";
            src = prev.fetchurl {
              url = "https://github.com/github/copilot-cli/releases/download/v${version}/copilot-linux-x64.tar.gz";
              hash = "sha256:8f9bb5f7e364c267265d1e24ac2aea69ed559ddb956719c6db12a353de6c5970";
            };
            sourceRoot = ".";
            installPhase = ''
              runHook preInstall
              install -Dm755 copilot "$out/bin/copilot"
              runHook postInstall
            '';
            postInstall = "";
          });
          nirimap = prev.stdenvNoCC.mkDerivation rec {
            pname = "nirimap";
            version = "0.2.0";

            src = prev.fetchurl {
              url = "https://github.com/alexandergknoll/nirimap/releases/download/v${version}/nirimap-v${version}-x86_64-linux.tar.gz";
              hash = "sha256-YDflubbAGgrbCzzUgpTA8GnBIZBImI3XZzzpv2y7Z4g=";
            };

            sourceRoot = ".";
            installPhase = ''
              runHook preInstall
              install -Dm755 nirimap "$out/bin/nirimap"
              runHook postInstall
            '';

            meta = {
              description = "Generate a visual map of a Niri workspace";
              homepage = "https://github.com/alexandergknoll/nirimap";
              license = prev.lib.licenses.mit;
              platforms = [ "x86_64-linux" ];
              mainProgram = "nirimap";
            };
          };
        })
        jj-starship.overlays.default
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
          determinate.nixosModules.default
          inputs.noctalia-greeter.nixosModules.default
          # inputs.ragenix.nixosModules.default
          ./configuration.nix
          {
            environment.systemPackages = [
              fh.packages.x86_64-linux.default
              pkgs.jj-starship
            ];
          }
        ];
      };

      mkHome = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          codex-desktop-linux.homeManagerModules.default
          {
            programs.codexDesktopLinux = {
              enable = true;
            };
          }
          ./home.nix
        ];
        extraSpecialArgs = {
          inherit inputs;
          username = "schlich";
          homeDirectory = "/home/schlich";
          stateVersion = "26.05";
        };
      };

      homeConfigurations.schlich = mkHome;

      homeCheck = pkgs.linkFarm "home-manager-check" (
        [
          {
            name = "activation";
            path = mkHome.activationPackage;
          }
        ]
        ++ lib.mapAttrsToList (checkName: path: {
          name = checkName;
          inherit path;
        }) mkHome.config.dotfiles.tooling.checks
      );
    in
    {
      inherit nixosConfigurations homeConfigurations;

      templates.default = {
        path = ./templates/default;
        description = "Nushell and Jujutsu project starter";
        welcomeText = ''
          # Project initialized

          Run `direnv allow` or `nix develop`, then replace the placeholder
          project metadata and add the language-specific tools you need.
        '';
      };

      packages.${system}.default = homeConfigurations.schlich.activationPackage;

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
        whitespace =
          pkgs.runCommand "whitespace-check"
            {
              nativeBuildInputs = [ pkgs.git ];
              src = ./.;
            }
            ''
              set +e
              git --no-pager diff --check --no-index --no-patch /dev/null "$src"
              status=$?
              set -e
              test "$status" -eq 1
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
