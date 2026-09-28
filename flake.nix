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
    gen-inspect = {
      url = "github:sini/gen-inspect";
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
    # Upstream packages OpenCode 2; nixpkgs still ships 1.x.
    opencode = {
      url = "github:anomalyco/opencode/v2.0.16";
    };
    paseo = {
      url = "github:getpaseo/paseo/main";
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
    typesafe-skills = {
      url = "github:typesafe-ai/skills";
      flake = false;
    };
    autoresearch = {
      url = "github:uditgoenka/autoresearch";
      flake = false;
    };
    # No flake upstream; bump the tag to update IWE.
    iwe = {
      url = "github:iwe-org/iwe/iwe-v0.24.2";
      flake = false;
    };
    iwe-skills = {
      url = "github:iwe-org/skills";
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
    # The same Tangled core on its own nixpkgs, for the spindle's microVM
    # guest image, which does not evaluate against this flake's nixpkgs.
    # Lock it to the `tangled` revision so the guest matches the spindle.
    tangled-image.url = "git+https://tangled.org/@tangled.org/core";
    tangled-dash = {
      url = "github:schlich/tangled-dash";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    xs = {
      url = "github:cablehead/xs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ptyZZZ = {
      url = "github:cablehead/ptyZZZ";
      flake = false;
    };
    nixbot = {
      url = "github:Mic92/nixbot";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
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
      nixUnitInputArgs = lib.concatStringsSep "\\\n  " (
        lib.mapAttrsToList (
          name: input: "--override-input ${lib.escapeShellArg name} ${lib.escapeShellArg "${input}"}"
        ) inputs
      );
      jjCiScript = pkgs.writeNuScriptBin "ci" (builtins.readFile ./jj/ci.nu);
      jjCi = pkgs.symlinkJoin {
        name = "ci";
        paths = [ jjCiScript ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram "$out/bin/ci" --prefix PATH : ${pkgs.git}/bin \
            --set JJ_CI_SOURCE_SHA256 ${builtins.hashFile "sha256" ./jj/ci.nu}
          # Deprecated alias for the former `jj-ci` name.
          ln -s ci "$out/bin/jj-ci"
        '';
      };
      xrWorkbench = pkgs.writeShellApplication {
        name = "xr-workbench";
        runtimeInputs = [
          pkgs.nodejs_24
          pkgs.pnpm
          pkgs.python3
        ];
        text = ''
          repo="$(pwd -P)"
          if [ "$#" -ge 2 ] && [ "$1" = "--repo" ]; then
            repo="$2"
            shift 2
          fi
          web="$repo/xr-workbench/web"
          if [ ! -f "$web/package.json" ]; then
            echo "Run xr-workbench from the repository root, or pass --repo PATH." >&2
            exit 2
          fi
          pnpm --dir "$web" install --frozen-lockfile
          exec pnpm --dir "$web" run dev -- --repo "$repo" "$@"
        '';
        meta.description = "Local IWSDK WebXR workbench for Nix, Nushell, and Jujutsu workflows";
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
              environment = user.environment;
              primary = user.primary;
            }) host.users;
          }) denEval.config.den.hosts.x86_64-linux
        )
      );
      homeEvaluation = pkgs.writeText "home-manager-evaluation" (
        # Instantiate the activation derivation without pulling its desktop closure into CI.
        builtins.unsafeDiscardStringContext
          "${denAsus.config.home-manager.users.schlich.home.activationPackage.drvPath}\n"
      );
      homeCheck = pkgs.linkFarm "home-manager-check" (
        [
          {
            name = "evaluation";
            path = homeEvaluation;
          }
        ]
        ++ lib.mapAttrsToList (checkName: path: {
          name = checkName;
          inherit path;
        }) denAsus.config.home-manager.users.schlich.dotfiles.tooling.checks
      );
      denHostEvaluationCheck = pkgs.writeText "den-host-evaluation" (
        # Keep all host derivations evaluated without adding their closures as
        # inputs. headless-system already evaluates and builds asus-headless.
        builtins.unsafeDiscardStringContext (
          lib.concatStringsSep "" (
            lib.mapAttrsToList (
              name: host:
              "${name}: ${host.config.networking.hostName}: ${host.config.system.build.toplevel.drvPath}\n"
            ) (removeAttrs denFlake.nixosConfigurations [ "asus-headless" ])
          )
        )
      );
      # The workstation with only its primary terminal, editor, and agent
      # desktop client; CI builds this closure, and the host evaluation check
      # covers the full one.
      denAsusPrimary = denAsus.extendModules {
        modules = [ { home-manager.users.schlich.dotfiles.alternates = false; } ];
      };
      # homelab with the nixbot module, before the host imports it; the App
      # IDs are placeholders until the GitHub App exists.
      nixbotHomelabEvaluationCheck = pkgs.writeText "nixbot-homelab-evaluation" (
        builtins.unsafeDiscardStringContext "${
          (denFlake.nixosConfigurations.homelab.extendModules {
            modules = [
              ./modules/nixos/nixbot.nix
              {
                services.nixbot.github = {
                  appId = 0;
                  oauthId = "placeholder";
                };
              }
            ];
          }).config.system.build.toplevel.drvPath
        }\n"
      );
      denPolicyCheck =
        pkgs.runCommand "den-policy-check"
          {
            nativeBuildInputs = [ pkgs.jq ];
          }
          ''
            jq --exit-status 'length > 0 and all(.[]; .policy.autoDeploy == false and .policy.requireReview == true and .policy.rollback == true)' ${denInventory}
            touch "$out"
          '';
    in
    {
      tests.systems.${system} = import ./tests.nix { inherit lib; };

      nixosConfigurations = denFlake.nixosConfigurations;
      den = denEval.config.den;
      gen-inspect = inputs.gen-inspect.lib;

      templates.default = {
        path = ./templates/default;
        description = "Nushell and Jujutsu project starter";
        welcomeText = ''
          # Project initialized

          Run `direnv allow` or `nix develop`, then replace the placeholder
          project metadata and add the language-specific tools you need.
        '';
      };

      templates.devenv = {
        path = ./templates/devenv;
        description = "Nushell and Jujutsu project starter using devenv";
        welcomeText = ''
          # Project initialized

          Run `direnv allow` or `devenv shell`, then enable the languages,
          services, and processes you need in `devenv.nix`.
        '';
      };

      packages.${system} = {
        default = denFlake.nixosConfigurations.asus.config.system.build.toplevel;
        headless = denFlake.nixosConfigurations.asus-headless.config.system.build.toplevel;
        desktop-primary = denAsusPrimary.config.system.build.toplevel;
        jj = pkgs.jujutsu;
        jjui = pkgs.jjui;
        xr-workbench = xrWorkbench;
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
          nix-fast-build
          nixd
          nixfmt-tree
          nodejs_24
          pnpm
          python3
          nushell
          prek
          ripgrep
          tlaplus
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
        xr-workbench = {
          type = "app";
          program = "${xrWorkbench}/bin/xr-workbench";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;

      # CI runs every attribute here as its own job, so a new check needs no
      # workflow change. Run the same set locally with `nix-fast-build`.
      checks.${system} = {
        den-host-evaluation = denHostEvaluationCheck;
        nixbot-homelab-evaluation = nixbotHomelabEvaluationCheck;
        den-inventory-tests =
          pkgs.runCommand "den-inventory-tests"
            {
              nativeBuildInputs = [ pkgs.nix-unit ];
            }
            ''
              export HOME="$(realpath .)"
              unset NIX_STORE
              export NIX_STORE_DIR=/nix/store
              export NIX_STATE_DIR="$HOME/nix-state"
              mkdir -p "$NIX_STATE_DIR/profiles/per-user"
              export NIX_REMOTE="$HOME/storedata"
              nix-unit \
                --show-trace \
                --extra-experimental-features flakes \
                --accept-flake-config \
                ${nixUnitInputArgs} \
                --flake ${./.}#tests.systems.${system}
              touch "$out"
            '';
        desktop-primary = denAsusPrimary.config.system.build.toplevel;
        headless-system = denFlake.nixosConfigurations.asus-headless.config.system.build.toplevel;
        den-policy = denPolicyCheck;
        dev-shell = pkgs.runCommand "dev-shell-check" { } ''
          test -x ${jjCi}/bin/ci
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
        nushell-agent =
          let
            # The test sources ../agent/agent.nu, so keep both in one tree.
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./agent/agent.nu
                ./tests/agent.nu
              ];
            };
          in
          pkgs.runCommand "nushell-agent-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${src}/tests/agent.nu
              touch "$out"
            '';
        ci-model =
          pkgs.runCommand "ci-model-check"
            {
              nativeBuildInputs = [ pkgs.tlaplus ];
            }
            ''
              cp ${./jj/JjCi.tla} JjCi.tla
              cp ${./jj/JjCi.cfg} JjCi.cfg
              cp ${./jj/JjCiLegacy.cfg} JjCiLegacy.cfg
              tlc -metadir "$TMPDIR/tlc" -config JjCi.cfg JjCi.tla
              # Each ownership invariant must catch the legacy behavior it
              # guards against, or it no longer tests anything.
              for invariant in $(sed -n '/^INVARIANTS/,$p' JjCiLegacy.cfg | tail -n +2); do
                { sed '/^INVARIANTS/,$d' JjCiLegacy.cfg; printf 'INVARIANT %s\n' "$invariant"; } > "legacy-$invariant.cfg"
                if tlc -metadir "$TMPDIR/tlc-$invariant" -config "legacy-$invariant.cfg" JjCi.tla > "legacy-$invariant.log"; then
                  echo "The legacy model satisfies $invariant, so it no longer detects that failure."
                  exit 1
                fi
                if ! grep -q "Invariant $invariant is violated" "legacy-$invariant.log"; then
                  cat "legacy-$invariant.log"
                  exit 1
                fi
              done
              touch "$out"
            '';
        ci-properties =
          let
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./jj/ci.nu
                ./jj/codex-session.nu
                ./jj/context-status.nu
                ./jj/guard.nu
                ./tests/pbt.nu
                ./tests/ci-properties.nu
                ./tests/codex-session-properties.nu
                ./tests/context-status-properties.nu
              ];
            };
          in
          pkgs.runCommand "ci-properties-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              nu --no-config-file -c "source ${src}/tests/ci-properties.nu"
              nu --no-config-file -c "source ${src}/tests/codex-session-properties.nu"
              nu --no-config-file -c "source ${src}/tests/context-status-properties.nu"
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
      };
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
