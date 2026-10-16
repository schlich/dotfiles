{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    den = {
      url = "github:denful/den/v0.18.0";
    };
    # Pushes Den's hosts over ssh (colmenaHive below), alongside
    # system-switch, which pulls Tangled's main on the host itself.
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.stable.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      inputs.nixpkgs.follows = "";
      inputs.home-manager.follows = "";
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
    ai-usagebar = {
      url = "github:akitaonrails/ai-usagebar";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fh = {
      url = "https://flakehub.com/f/DeterminateSystems/fh/*.tar.gz";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    codex-desktop-linux = {
      url = "github:ilysenko/codex-desktop-linux";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Anthropic's official Linux build of Claude Desktop, which nixpkgs lacks.
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
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
    effective-html = {
      url = "github:plannotator/effective-html";
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
    dicta = {
      url = "github:schlich/dicta";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    fieldnotes = {
      url = "github:schlich/fieldnotes";
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
    # The `pst` Nushell module (OSC 7501 program status) that ci reports its
    # phases with and the shell imports; the ci input follows it.
    osc7501-nu = {
      url = "github:schlich/osc7501.nu";
      flake = false;
    };
    # The `ci` trunk workflow with its companions and `ci tower`, hosted on
    # Tangled and fetched from its GitHub mirror. Every workspace runs the
    # version this lock pins; `nix flake update ci` moves to a newer one.
    ci = {
      url = "github:schlich/ci";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.osc7501-nu.follows = "osc7501-nu";
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
      jjCi = inputs.ci.packages.${system}.ci;
      jjCiLifecycle = inputs.ci.packages.${system}.jj-ci-lifecycle;
      xrWorkbench = pkgs.writeShellApplication {
        name = "xr-workbench";
        runtimeInputs = [
          pkgs.nodejs_24
          pkgs.pnpm
          pkgs.python3
          pkgs.d2
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
      quotaAdvisor = pkgs.writeShellApplication {
        name = "quota-advisor";
        runtimeInputs = [ pkgs.python3 ];
        text = ''
          export PYTHONPATH=${./tools/quota-advisor/src}
          exec python3 -m quota_advisor.cli "$@"
        '';
        meta.description = "Explainable Codex and Claude subscription pacing advisor";
      };
      # Anything the devshell does not carry falls through to whatever a
      # one-off `home-manager switch` left in ~/.nix-profile; this reports that
      # fall-through, and how far behind the lock the resolved claude is.
      profileDrift = pkgs.writeNuScriptBin "profile-drift" ''
        const expected_claude = "${pkgs.claude-code.version}"
        ${builtins.readFile ./tools/profile-drift.nu}
      '';
      lib = nixpkgs.lib;
      iwe = import ./modules/tooling/knowledge/iwe-package.nix { inherit inputs lib pkgs; };
      marimohub = import ./modules/tooling/knowledge/marimohub-package.nix { inherit lib pkgs; };
      workbench = import ./workbench { inherit pkgs lib iwe; };
      workbenchImages = lib.mapAttrs' (
        name: environment: lib.nameValuePair "workbench-image-${name}" environment.image
      ) workbench.environments;
      # The workbench corpus, tests, and environments without the rest of the
      # repository, so unrelated edits do not rebuild the checks.
      workbenchSource = lib.fileset.toSource {
        root = ./workbench;
        fileset = ./workbench;
      };
      workbenchDemo = workbench.environments.visualization;
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
      # Keep every host derivation evaluated without adding its closure as an
      # input, one check per host: all of them in one evaluator came within
      # 0.3 GiB of ci's 6 GiB evaluation budget. headless-system already
      # evaluates and builds asus-headless, and colmena-hive-NAME evaluates
      # each deployed host. Disposable hosts are left to remoteChecks.
      denHostEvaluationChecksFor = lib.mapAttrs' (
        name: host:
        lib.nameValuePair "den-host-${name}" (
          pkgs.writeText "den-host-${name}" (
            builtins.unsafeDiscardStringContext "${name}: ${host.config.networking.hostName}: ${host.config.system.build.toplevel.drvPath}\n"
          )
        )
      );
      denHostEvaluationChecks = denHostEvaluationChecksFor (
        removeAttrs denFlake.nixosConfigurations (
          [ "asus-headless" ] ++ builtins.attrNames deployHosts ++ builtins.attrNames remoteCheckHosts
        )
      );
      # Hosts whose inventory policy marks them disposable still have to
      # evaluate, but GitHub Actions checks them after each push without
      # blocking: ci land builds only `checks`.
      remoteCheckHosts = lib.filterAttrs (
        _: host: host.policy.criticality == "disposable"
      ) denEval.config.den.hosts.${system};
      remoteHostEvaluationChecks = denHostEvaluationChecksFor (
        builtins.intersectAttrs remoteCheckHosts denFlake.nixosConfigurations
      );
      # The workstation with only its primary terminal, editor, and agent
      # desktop client; CI builds this closure, and colmena-hive-asus
      # evaluates the full one.
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
      # homelab with the marimohub aspect, before the host includes it. The
      # login domain is a placeholder until the hub is enabled there.
      marimohubHomelabEvaluationCheck = pkgs.writeText "marimohub-homelab-evaluation" (
        builtins.unsafeDiscardStringContext "${
          (denFlake.nixosConfigurations.homelab.extendModules {
            modules = [
              ./modules/nixos/workbench-hub.nix
              { services.marimohub.auth.allowedEmailDomains = [ "example.com" ]; }
            ];
          }).config.system.build.toplevel.drvPath
        }\n"
      );
      # Colmena pushes Den's hosts over ssh. Each node re-evaluates the module
      # list Den resolved for the host (den/inventory.nix keeps it as
      # denModules), and the inventory's typed deploy and profile facts supply
      # the target and tags, so `colmena apply --on @server` needs no
      # hostname lists here.
      deployHosts = lib.filterAttrs (_: host: host.deploy.enable) denEval.config.den.hosts.${system};
      colmenaHive = inputs.colmena.lib.makeHive (
        {
          meta = {
            nixpkgs = import nixpkgs { inherit system; };
            specialArgs = { inherit inputs; };
            # Name the hosts with --on; nothing deploys the whole fleet at once.
            allowApplyAll = false;
          };
        }
        // lib.mapAttrs (name: host: {
          imports = denFlake.nixosConfigurations.${name}.denModules ++ [
            # What nixpkgs' flake lib.nixosSystem adds and Colmena's direct
            # eval-config.nix call lacks: the flake's version and revision,
            # and its source path.
            {
              system.nixos.versionSuffix = nixpkgs.lib.trivial.versionSuffix;
              system.nixos.revision = nixpkgs.lib.trivial.revisionWithDefault null;
              nixpkgs.flake.source = nixpkgs.outPath;
            }
          ];
          deployment = {
            inherit (host.deploy) targetHost targetUser;
            allowLocalDeployment = host.deploy.targetHost == null;
            tags = lib.unique (
              [
                host.profile.role
                host.policy.criticality
              ]
              ++ lib.optional (host.profile.desktop != "none") host.profile.desktop
            );
          };
        }) deployHosts
      );
      # Colmena must deploy the system nixosConfigurations builds, which is
      # what CI checks and system-switch activates. Comparing them evaluates
      # each host twice, so every host gets its own check: all of them in one
      # evaluator outgrew ci's 6 GiB evaluation budget.
      colmenaHiveChecks = lib.mapAttrs' (
        name: _:
        let
          fromHive = colmenaHive.toplevel.${name}.drvPath;
          fromDen = denFlake.nixosConfigurations.${name}.config.system.build.toplevel.drvPath;
        in
        lib.nameValuePair "colmena-hive-${name}" (
          pkgs.writeText "colmena-hive-${name}" (
            assert lib.assertMsg (
              fromHive == fromDen
            ) "colmenaHive.${name} (${fromHive}) differs from nixosConfigurations.${name} (${fromDen})";
            builtins.unsafeDiscardStringContext "${name}: ${fromHive}\n"
          )
        )
      ) deployHosts;
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
      inherit colmenaHive;
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
        ci = jjCi;
        jj = pkgs.jujutsu;
        jjui = pkgs.jjui;
        jj-ci-lifecycle = jjCiLifecycle;
        xr-workbench = xrWorkbench;
        quota-advisor = quotaAdvisor;
        inherit marimohub;
        workbench = workbench.cli;
      }
      // workbenchImages;

      devShells.${system} = {
        # git and jj come from the user profile, whose wrappers carry the
        # identity, credential helper and fix tools from vcs.nix; plain copies
        # here would shadow them on PATH.
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            bat
            claude-code
            colmena
            d2
            difftastic
            fd
            gh
            jq
            jjCi
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
            profileDrift
            ripgrep
            tlaplus
          ];
        };

        # Author executable knowledge: the demo environment's Python, marimo,
        # and IWE, plus the workbench CLI.
        workbench = pkgs.mkShellNoCC {
          packages = [
            workbenchDemo.runtime
            workbench.cli
            pkgs.nushell
            pkgs.jujutsu
          ];
          WORKBENCH_ENVIRONMENT = workbenchDemo.name;
          shellHook = ''
            export IWE_WORKSPACE="$PWD/workbench"
          '';
        };
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
        quota-advisor = {
          type = "app";
          program = "${quotaAdvisor}/bin/quota-advisor";
        };
        workbench = {
          type = "app";
          program = "${workbench.cli}/bin/workbench";
        };
      };

      formatter.${system} = pkgs.nixfmt-tree;

      # CI runs every attribute here as its own job, so a new check needs no
      # workflow change. Run the same set locally with `nix-fast-build`.
      checks.${system} = {
        quota-advisor = pkgs.runCommand "quota-advisor-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          cd ${./tools/quota-advisor}
          PYTHONPATH=src python3 -m unittest discover -s tests -v
          touch "$out"
        '';
        marimohub = marimohub;
        # One Markdown file as an IWE node and a marimo notebook: IWE
        # validates the corpus, marimo executes the demo in the Nix
        # environment its frontmatter names, an editor save keeps the IWE
        # metadata, and JJ sees only the edited line.
        workbench =
          pkgs.runCommand "workbench-check"
            {
              nativeBuildInputs = [
                workbench.cli
                workbenchDemo.runtime
                pkgs.jujutsu
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              cp -r ${workbenchSource} workspace
              chmod -R u+w workspace
              cd workspace

              export JJ_USER=check JJ_EMAIL=check@localhost
              jj git init --quiet
              jj commit --quiet -m baseline
              # roundtrip.py reads `jj diff` itself when .jj exists.
              python tests/roundtrip.py "$PWD"
              test "$(jj diff --name-only)" = knowledge/investigations/executable-knowledge-demo.md
              jj restore --quiet

              workbench check .
              workbench export knowledge/investigations/executable-knowledge-demo.md -o "$TMPDIR/demo.html"
              python tests/rendered.py "$TMPDIR/demo.html" ${workbenchDemo.name}
              touch "$out"
            '';
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
          test -x ${pkgs.claude-code}/bin/claude
          test -x ${profileDrift}/bin/profile-drift
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
        nushell-parse =
          let
            # profile-drift.nu is a fragment the flake completes, so check
            # the installed script in its place.
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.difference (lib.fileset.fileFilter (
                file: file.hasExt "nu"
              ) ./.) ./tools/profile-drift.nu;
            };
          in
          pkgs.runCommand "nushell-parse-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              cd ${src}
              find . -name '*.nu' -print0 \
                | xargs -0 ${pkgs.nushell}/bin/nu --no-config-file ${./tests/nu-parse.nu} \
                  ${profileDrift}/bin/profile-drift
              touch "$out"
            '';
        # The ci workflow's model, machine, and property tests run as the ci
        # repository's own flake checks.
        ruff =
          pkgs.runCommand "ruff-check"
            {
              nativeBuildInputs = [ pkgs.ruff ];
            }
            ''
              ruff check --no-cache --config ${./workbench/ruff.toml} ${./workbench/python} ${./workbench/tests}
              ruff format --no-cache --config ${./workbench/ruff.toml} --check ${./workbench/python} ${./workbench/tests}
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
      // colmenaHiveChecks
      // denHostEvaluationChecks;

      # Checks that report without gating a landing: GitHub Actions' nix-ci
      # workflow builds them after each push, and ci land leaves them out.
      # They cover disposable hosts and homelab with modules it has not
      # adopted yet.
      remoteChecks.${system} = remoteHostEvaluationChecks // {
        marimohub-homelab-evaluation = marimohubHomelabEvaluationCheck;
        nixbot-homelab-evaluation = nixbotHomelabEvaluationCheck;
      };
    };
  nixConfig = {
    extra-substituters = [
      "https://cache.flakehub.com/"
    ];
    trusted-users = [ "schlich" ];
  };
}
