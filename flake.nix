{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    determinate = {
      url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    };
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    den = {
      url = "github:denful/den/v0.18.0";
    };
    nushellWith = {
      url = "github:YPares/nushellWith/master";
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
      inputs.nixpkgs.follows = "nixpkgs";
    };
    niri = {
      url = "github:epireyn/niri-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia/cachix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia-greeter = {
      url = "github:noctalia-dev/noctalia-greeter";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ai-usagebar = {
      url = "github:akitaonrails/ai-usagebar";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fh = {
      url = "https://flakehub.com/f/DeterminateSystems/fh/*.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
    tangled = {
      url = "git+https://tangled.org/@tangled.org/core";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    xs = {
      url = "github:cablehead/xs";
      inputs.nixpkgs.follows = "nixpkgs";
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
      jjCiScript = pkgs.writeNuScriptBin "jj-ci" (builtins.readFile ./jj/ci.nu);
      jjCi = pkgs.symlinkJoin {
        name = "jj-ci";
        paths = [ jjCiScript ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram "$out/bin/jj-ci" --prefix PATH : ${pkgs.git}/bin
        '';
      };
      lib = nixpkgs.lib;
      denEval = lib.evalModules {
        modules = [
          inputs.den.flakeModule
          ./den
        ];
        specialArgs = { inherit inputs; };
      };
      denFlake = denEval.config.flake;
      denAsus = denFlake.nixosConfigurations.asus;
      denInventory = pkgs.writeText "den-inventory.json" (
        builtins.toJSON (
          lib.mapAttrs (_: host: {
            profile = host.profile;
            policy = host.policy;
            users = lib.mapAttrs (_: user: {
              classes = user.classes;
              primary = user.primary;
            }) host.users;
          }) denEval.config.den.hosts.x86_64-linux
        )
      );
      homeCheck = pkgs.linkFarm "home-manager-check" (
        [
          {
            name = "activation";
            path = denAsus.config.home-manager.users.schlich.home.activationPackage;
          }
        ]
        ++ lib.mapAttrsToList (checkName: path: {
          name = checkName;
          inherit path;
        }) denAsus.config.home-manager.users.schlich.dotfiles.tooling.checks
      );
      denHostEvaluationCheck = pkgs.runCommand "den-host-evaluation-check" { } ''
        cat > "$out" <<'EOF'
        ${lib.concatStringsSep "" (
          lib.mapAttrsToList (
            name: host: "${name}: ${host.config.networking.hostName}\n"
          ) denFlake.nixosConfigurations
        )}
        EOF
      '';
      denHostBuildChecks = lib.mapAttrs' (
        name: host: lib.nameValuePair "den-host-build-${name}" host.config.system.build.toplevel
      ) denFlake.nixosConfigurations;
      denPolicyCheck =
        pkgs.runCommand "den-policy-check"
          {
            nativeBuildInputs = [ pkgs.jq ];
          }
          ''
            jq --exit-status 'length == 4 and all(.[]; .policy.autoDeploy == false and .policy.requireReview == true and .policy.rollback == true)' ${denInventory}
            touch "$out"
          '';
    in
    {
      nixosConfigurations = denFlake.nixosConfigurations;
      den = denEval.config.den;

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
        default = denFlake.nixosConfigurations.asus.config.system.build.toplevel;
        headless = denFlake.nixosConfigurations.asus-headless.config.system.build.toplevel;
        jj = pkgs.jujutsu;
        jjui = pkgs.jjui;
      };

      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          bat
          difftastic
          fd
          gh
          git
          jq
          jjCi
          jujutsu
          jjui
          nil
          nixd
          nixfmt-tree
          nushell
          prek
          ripgrep
        ];
      };

      apps.${system} = {
        jj = {
          type = "app";
          program = "${pkgs.jujutsu}/bin/jj";
        };
        jjui = {
          type = "app";
          program = "${pkgs.jjui}/bin/jjui";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system} = {
        den-host-evaluation = denHostEvaluationCheck;
        den-policy = denPolicyCheck;
        dev-shell = pkgs.runCommand "dev-shell-check" { } ''
          test -x ${jjCi}/bin/jj-ci
          test -x ${pkgs.jujutsu}/bin/jj
          test -x ${pkgs.gh}/bin/gh
          touch "$out"
        '';
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
              nativeBuildInputs = [ pkgs.ripgrep ];
            }
            ''
              matches="$(${pkgs.ripgrep}/bin/rg \
                --hidden \
                --glob '!.git/**' \
                --glob '!.jj/**' \
                --glob '!.direnv/**' \
                --glob '!packages/**' \
                --glob '!**/node_modules/**' \
                --glob '!result*' \
                '[[:blank:]]$' . || true)"
              if [ -n "$matches" ]; then
                printf '%s\n' "$matches"
                exit 1
              fi
              touch "$out"
            '';
      }
      // denHostBuildChecks;
    };
  nixConfig = {
    extra-substituters = [
      "https://noctalia.cachix.org"
      "https://cache.flakehub.com/"
    ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];
    trusted-users = [ "schlich" ];
  };
}
