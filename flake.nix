{
  description = "Modular Home Manager and NixOS configuration";

  inputs = {
    # Each group is a flake of at most six inputs or further groups
    # (github:schlich/honeycomb). `nix flake update terminal/shell/xs` updates
    # one input.
    system.url = "path:./lib/inputs/system";
    builds.url = "path:./lib/inputs/builds";
    desktop.url = "path:./lib/inputs/desktop";
    terminal.url = "path:./lib/inputs/terminal";
    agents.url = "path:./lib/inputs/agents";

    # What follows what across the groups, which only the root can say.
    system.inputs.home-manager.inputs.nixpkgs.follows = "system/nixpkgs";
    system.inputs.clan-core.inputs.nixpkgs.follows = "system/nixpkgs";
    system.inputs.impermanence.inputs.nixpkgs.follows = "";
    system.inputs.impermanence.inputs.home-manager.follows = "";
    system.inputs.agenix.inputs.nixpkgs.follows = "system/nixpkgs";
    builds.inputs.iets.inputs.nixpkgs.follows = "system/nixpkgs";
    builds.inputs.nix-grpc-store.inputs.nixpkgs.follows = "system/nixpkgs";
    builds.inputs.nixbot.inputs.nixpkgs.follows = "system/nixpkgs";
    desktop.inputs.niri.inputs.nixpkgs.follows = "system/nixpkgs";
    desktop.inputs.noc-minimizer.inputs.nixpkgs.follows = "system/nixpkgs";
    desktop.inputs.dicta.inputs.nixpkgs.follows = "system/nixpkgs";
    desktop.inputs.ai-usagebar.inputs.nixpkgs.follows = "system/nixpkgs";
    desktop.inputs.honeycomb.inputs.nixpkgs.follows = "system/nixpkgs";
    terminal.inputs.luvus.inputs.nixpkgs.follows = "system/nixpkgs";
    terminal.inputs.shell.inputs.nushellWith.inputs.nixpkgs.follows = "system/nixpkgs";
    terminal.inputs.shell.inputs.xs.inputs.nixpkgs.follows = "system/nixpkgs";
    terminal.inputs.shell.inputs.rex.inputs.nixpkgs.follows = "system/nixpkgs";
    terminal.inputs.vcs.inputs.ci.inputs.nixpkgs.follows = "system/nixpkgs";
    terminal.inputs.vcs.inputs.ci.inputs.osc7501-nu.follows = "terminal/shell/osc7501-nu";
    # Only its non-flake default.nix uses flake-compat. Nix 2.34 cannot
    # refetch the lix tarball it locks (the locked URL keeps a ?rev= that
    # the fetch drops), which fails nixbot's prefetch once the source
    # leaves homelab's store.
    agents.inputs.fieldnotes.inputs.nixpkgs.follows = "system/nixpkgs";
    agents.inputs.clients.inputs.llm-agents.inputs.nixpkgs.follows = "system/nixpkgs";
    agents.inputs.clients.inputs.continuum-ide.inputs.nixpkgs.follows = "system/nixpkgs";
    agents.inputs.clients.inputs.paseo.inputs.nixpkgs.follows = "system/nixpkgs";
  };

  outputs =
    groups:
    let
      # The rest of this file, and every module, sees the groups' sources
      # under one flat `inputs`, by name.
      inputGroups = [
        "system"
        "builds"
        "desktop"
        "terminal"
        "agents"
      ];
      inputs = builtins.foldl' (all: group: all // groups.${group}.sources) {
        inherit (groups) self;
      } inputGroups;
      # Where each input sits among the groups: `terminal/shell/xs`.
      inputPaths = builtins.foldl' (
        all: group: all // builtins.mapAttrs (_: path: "${group}/${path}") groups.${group}.paths
      ) { } inputGroups;
      inherit (inputs) nixpkgs nushellWith;
      system = "x86_64-linux";
      overlays = [
        # The hosts' Nushell, so the checks run the scripts with it.
        (import ./modules/nixos/base/user/nushell-package.nix)
        nushellWith.overlays.default
      ];
      pkgs = import nixpkgs {
        inherit system overlays;
        config.allowUnfree = true;
      };
      nixUnitInputArgs = lib.concatStringsSep "\\\n  " (
        lib.mapAttrsToList (
          name: path: "--override-input ${lib.escapeShellArg path} ${lib.escapeShellArg "${inputs.${name}}"}"
        ) inputPaths
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
      jev = import ./jev/package.nix { inherit pkgs; };
      quotaAdvisor = pkgs.writeShellApplication {
        name = "quota-advisor";
        runtimeInputs = [ pkgs.python3 ];
        # --jev runs this repository's jev; QUOTA_ADVISOR_JEV overrides it.
        text = ''
          export PYTHONPATH=${./tools/quota-advisor/src}
          export QUOTA_ADVISOR_JEV="''${QUOTA_ADVISOR_JEV:-${jev}/bin/jev}"
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
      bombadil = import ./lib/bombadil.nix { inherit lib pkgs; };
      dagger = import ./modules/programs/vcs/dagger-package.nix { inherit lib pkgs; };
      inherit (pkgs) iwe;
      marimohub = import ./modules/tooling/knowledge/marimohub-package.nix { inherit lib pkgs; };
      jjGraph = import ./tools/jj-graph { inherit lib pkgs; };
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
      # Home Manager runs apart from the system; `nh home switch` applies
      # homeConfigurations."USER@HOST" (den/inventory.nix).
      denAsusHome = denFlake.homeConfigurations."schlich@asus";
      denInventory = pkgs.writeText "den-inventory.json" (
        builtins.toJSON (
          lib.mapAttrs (_: host: {
            profile = host.profile;
            hardware = host.hardware;
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
        builtins.unsafeDiscardStringContext "${denAsusHome.activationPackage.drvPath}\n"
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
        }) denAsusHome.config.dotfiles.tooling.checks
      );
      # Keep every host derivation evaluated without adding its closure as an
      # input, one check per host: all of them in one evaluator came within
      # 0.3 GiB of 6 GiB, the whole of ci's evaluation budget. Disposable
      # hosts are left to remoteChecks.
      denHostEvaluationChecksFor = lib.mapAttrs' (
        name: host:
        lib.nameValuePair "den-host-${name}" (
          pkgs.writeText "den-host-${name}" (
            builtins.unsafeDiscardStringContext "${name}: ${host.config.networking.hostName}: ${host.config.system.build.toplevel.drvPath}\n"
          )
        )
      );
      denHostEvaluationChecks = denHostEvaluationChecksFor (
        removeAttrs denFlake.nixosConfigurations (builtins.attrNames remoteCheckHosts)
      );
      # Hosts whose inventory policy marks them disposable still have to
      # evaluate, but GitHub Actions checks them after each push without
      # blocking: the luvus gate and nixbot build only `gateChecks`.
      remoteCheckHosts = lib.filterAttrs (
        _: host: host.policy.criticality == "disposable"
      ) denEval.config.den.hosts.${system};
      # tests/den-config.nix, one check per group, run while the check
      # evaluates; a failure names each test with what it got and expected.
      denConfigTests = import ./tests/den-config.nix {
        inherit lib;
        inherit (denFlake) nixosConfigurations homeConfigurations;
        hosts = denEval.config.den.hosts.${system};
      };
      denConfigTestChecksFor = lib.mapAttrs' (
        group: tests:
        let
          failures = lib.runTests tests;
        in
        lib.nameValuePair "den-config-tests-${group}" (
          pkgs.writeText "den-config-tests-${group}" (
            assert lib.assertMsg (failures == [ ])
              "den-config-tests-${group} failed:\n${lib.generators.toPretty { } failures}";
            lib.concatMapStrings (test: "${test}\n") (builtins.attrNames tests)
          )
        )
      );
      denConfigTestChecks = denConfigTestChecksFor (
        removeAttrs denConfigTests (builtins.attrNames remoteCheckHosts)
      );
      # A disposable host's configuration tests go with its evaluation.
      remoteHostEvaluationChecks =
        denHostEvaluationChecksFor (builtins.intersectAttrs remoteCheckHosts denFlake.nixosConfigurations)
        // denConfigTestChecksFor (builtins.intersectAttrs remoteCheckHosts denConfigTests);
      # The workstation's home with only its primary terminal, editor, and
      # agent desktop client; CI builds this closure after landing, and
      # home-manager evaluates the full one.
      denAsusPrimary = denAsusHome.extendModules {
        modules = [ { dotfiles.alternates = false; } ];
      };
      # homelab with nixbot running, before nixbot-register names the GitHub
      # App and encrypts its secrets; the IDs and secrets are placeholders
      # until it does.
      nixbotHomelabEvaluationCheck = pkgs.writeText "nixbot-homelab-evaluation" (
        builtins.unsafeDiscardStringContext "${
          (denFlake.nixosConfigurations.homelab.extendModules {
            modules = [
              {
                services.nixbot = {
                  enable = lib.mkForce true;
                  github = {
                    appId = lib.mkDefault 0;
                    oauthId = lib.mkDefault "placeholder";
                  };
                };
                age.secrets =
                  lib.genAttrs
                    [
                      "nixbot-github-app"
                      "nixbot-github-webhook-secret"
                      "nixbot-github-oauth-secret"
                    ]
                    (name: {
                      file = lib.mkForce (builtins.toFile "${name}.age" "");
                    });
              }
            ];
          }).config.system.build.toplevel.drvPath
        }\n"
      );
      # What nixbot-register registers and writes, from homelab's
      # modules/nixos/builds/nixbot.nix: the GitHub App manifest, the topic nixbot
      # imports, and where the App's IDs and secrets go.
      nixbotRegistration = denFlake.nixosConfigurations.homelab.config.dotfiles.nixbot.registration;
      nixbotRegister = import ./tools/nixbot-register {
        inherit pkgs;
        registration = nixbotRegistration;
      };
      # homelab with the marimohub aspect, before the host includes it. The
      # login domain is a placeholder until the hub is enabled there.
      marimohubHomelabEvaluationCheck = pkgs.writeText "marimohub-homelab-evaluation" (
        builtins.unsafeDiscardStringContext "${
          (denFlake.nixosConfigurations.homelab.extendModules {
            modules = [
              ./modules/nixos/services/workbench-hub.nix
              { services.marimohub.auth.allowedEmailDomains = [ "example.com" ]; }
            ];
          }).config.system.build.toplevel.drvPath
        }\n"
      );
      # homelab with discord-digest running, before its owner encrypts
      # secrets/discord-digest/env.age; the secret is a placeholder until then.
      discordDigestHomelabEvaluationCheck = pkgs.writeText "discord-digest-homelab-evaluation" (
        builtins.unsafeDiscardStringContext "${
          (denFlake.nixosConfigurations.homelab.extendModules {
            modules = [
              (
                { config, ... }:
                {
                  services.discord-digest = {
                    enable = lib.mkForce true;
                    environmentFile = lib.mkForce config.age.secrets.discord-digest-env.path;
                  };
                  age.secrets.discord-digest-env.file = lib.mkForce (builtins.toFile "discord-digest-env.age" "");
                }
              )
            ];
          }).config.system.build.toplevel.drvPath
        }\n"
      );
      # Clan pushes Den's hosts over ssh. `clan machines update NAME` builds
      # this flake's nixosConfigurations.NAME, the system CI checks and
      # system-switch activates; Clan's own machine for each host, which
      # supplies its vars and deploy settings, imports the module list Den
      # resolved for it (den/inventory.nix keeps it as denModules). The
      # inventory's typed deploy and profile facts supply the target and
      # tags, so no hostname lists live here.
      deployHosts = lib.filterAttrs (_: host: host.deploy.enable) denEval.config.den.hosts.${system};
      clan = inputs.clan-core.lib.clan {
        inherit (inputs) self;
        meta.name = "dotfiles";
        specialArgs = { inherit inputs; };
        inventory.machines = lib.mapAttrs (_: host: {
          deploy = {
            # A host with no target applies itself, over ssh to localhost.
            targetHost = "${host.deploy.targetUser}@${
              if host.deploy.targetHost == null then "localhost" else host.deploy.targetHost
            }";
            # Build where the deploy runs and copy the closure over.
            buildHost = "localhost";
          };
          tags = lib.unique (
            [
              host.profile.role
              host.policy.criticality
            ]
            ++ lib.optional (host.profile.desktop != "none") host.profile.desktop
          );
        }) deployHosts;
        machines = lib.mapAttrs (name: _: {
          imports = denFlake.nixosConfigurations.${name}.denModules;
          # The same modules give the same package set, so take Den's rather
          # than instantiating nixpkgs a second time: clan-machine-NAME
          # evaluates both systems at once, and homelab's two package sets
          # outgrew ci's 4 GiB evaluation budget (2026-10-16).
          _module.args.pkgs = lib.mkForce denFlake.nixosConfigurations.${name}.pkgs;
          # Clan's zfs module gives every machine the install ISO's hostId,
          # recommended defaults or not; keep the one Den resolves (none
          # unless a host sets it).
          networking.hostId = lib.mkOverride 999 null;
          clan.core = {
            # Clan's recommended defaults (networkd, mDNS, nix settings,
            # debugging tools) would change the system Den builds.
            enableRecommendedDefaults = false;
            # Name the machines; nothing deploys the whole fleet at once.
            deployment.requireExplicitUpdate = true;
          };
        }) deployHosts;
      };
      # Clan's machine must be the system nixosConfigurations builds, or its
      # vars and settings describe a system that is never deployed. Comparing
      # them evaluates each host twice, which made homelab's comparison the
      # largest check: 4.8 GiB under nix-eval-jobs against ci's 6 GiB
      # evaluation budget (2026-10-16). So the comparison reports in
      # remoteChecks and den-host-NAME gates each deployed host's evaluation.
      clanMachineChecks = lib.mapAttrs' (
        name: _:
        let
          fromClan = clan.config.nixosConfigurations.${name}.config.system.build.toplevel.drvPath;
          fromDen = denFlake.nixosConfigurations.${name}.config.system.build.toplevel.drvPath;
        in
        lib.nameValuePair "clan-machine-${name}" (
          pkgs.writeText "clan-machine-${name}" (
            assert lib.assertMsg (
              fromClan == fromDen
            ) "Clan's machine ${name} (${fromClan}) differs from nixosConfigurations.${name} (${fromDen})";
            builtins.unsafeDiscardStringContext "${name}: ${fromClan}\n"
          )
        )
      ) deployHosts;
      denPolicyCheck =
        pkgs.runCommand "den-policy-check"
          {
            nativeBuildInputs = [ pkgs.jq ];
          }
          ''
            # A host may deploy itself only with health checks to watch.
            jq --exit-status 'length > 0 and all(.[]; .policy.requireReview == true and .policy.rollback == true and (.policy.autoDeploy == false or (.policy.healthChecks | length) > 0))' ${denInventory}
            touch "$out"
          '';
    in
    {
      tests.systems.${system} = import ./tests.nix { inherit lib; };

      # Den's systems, not Clan's: the clan CLI deploys these.
      nixosConfigurations = denFlake.nixosConfigurations;
      # Standalone homes named USER@HOST, which `nh home switch` picks for
      # the current user and host. A home the system embeds (homeActivation
      # = "embedded", as on homelab) is Den's flake.embeddedHomes instead,
      # which stays internal: only its system activates it.
      homeConfigurations = denFlake.homeConfigurations;
      inherit (clan.config) clanInternals;
      clan = clan.config;
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
        home = denAsusHome.activationPackage;
        headless = denFlake.nixosConfigurations.asus-headless.config.system.build.toplevel;
        desktop-primary = denAsusPrimary.activationPackage;
        ci = jjCi;
        inherit dagger;
        jj = pkgs.jujutsu;
        jjui = pkgs.jjui;
        jj-ci-lifecycle = jjCiLifecycle;
        jj-graph = jjGraph.package;
        xr-workbench = xrWorkbench;
        quota-advisor = quotaAdvisor;
        nixbot-register = nixbotRegister;
        inherit marimohub;
        workbench = workbench.cli;
        # A Rust build this flake owns, with a `timings` output holding
        # cargo's build timing report (lib/with-cargo-timings.nix).
        jj-hunk = import ./modules/programs/vcs/jj-hunk-package.nix { inherit inputs lib pkgs; };
        taskers = import ./modules/tooling/terminals/taskers/package.nix { inherit inputs lib pkgs; };
        webterm = import ./modules/tooling/terminals/webterm/package.nix { inherit inputs lib pkgs; };
        # nu_plugin_ghostty and the libghostty-vt it links, which nixpkgs
        # ships too old (modules/programs/shell/nu-plugin-ghostty).
        libghostty-vt =
          pkgs.callPackage ./modules/programs/shell/nu-plugin-ghostty/libghostty-vt/package.nix
            { };
        nu-plugin-ghostty = import ./modules/programs/shell/nu-plugin-ghostty/package.nix {
          inherit inputs lib pkgs;
        };
      }
      // workbenchImages;

      devShells.${system} = {
        # git and jj come from the user profile, whose wrappers carry the
        # identity, credential helper and fix tools from vcs.nix; plain copies
        # here would shadow them on PATH.
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            bat
            # Replays and inspects the keymap checks' traces (tests/bombadil).
            bombadil.package
            claude-code
            # The CLI must match the clan-core lib that builds `clan` above.
            inputs.clan-core.packages.${system}.clan-cli
            d2
            # `dagger check` runs the flake checks in containers (docs/delivery/dagger.md).
            dagger
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
        jj-graph = {
          type = "app";
          program = "${jjGraph.package}/bin/jj-graph";
        };
        xr-workbench = {
          type = "app";
          program = "${xrWorkbench}/bin/xr-workbench";
        };
        quota-advisor = {
          type = "app";
          program = "${quotaAdvisor}/bin/quota-advisor";
        };
        nixbot-register = {
          type = "app";
          program = "${nixbotRegister}/bin/nixbot-register";
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
        # No collection may newly pass six members (github:schlich/honeycomb).
        # The ones that already do (lib/census/baseline.nix) warn when they
        # grow, until regrouped.
        honeycomb-census =
          let
            honeycomb = inputs.honeycomb.lib;
            census = import ./lib/census {
              inherit lib honeycomb;
              root = ./.;
            };
            result = honeycomb.audit {
              inherit census;
              baseline = import ./lib/census/baseline.nix;
            };
          in
          pkgs.writeText "honeycomb-census" (
            assert lib.assertMsg (honeycomb.clean result)
              "honeycomb-census failed:\n${honeycomb.report result}";
            lib.warnIf (result.grown != { })
              "honeycomb: collections already over six grew: ${honeycomb.growth result}"
              (builtins.toJSON census)
          );
        quota-advisor = pkgs.runCommand "quota-advisor-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
          cd ${./tools/quota-advisor}
          PYTHONPATH=src python3 -m unittest discover -s tests -v
          touch "$out"
        '';
        # discord-digest's build runs its tests.
        discord-digest = pkgs.callPackage ./tools/discord-digest/package.nix { };
        # jj-graph's build runs its lints, its Hegel properties (some in real
        # jj repositories), and its conformance to spec/Normalize.qnt; the
        # model check simulates and model checks the specifications.
        jj-graph = jjGraph.package;
        jj-graph-model = jjGraph.model;
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
        # Every group flake under lib/inputs declares exactly what flake.lock
        # holds for it; Nix would otherwise ignore the difference.
        inputs-locked =
          let
            stale = import ./lib/inputs/locked.nix {
              inherit lib;
              root = ./.;
            };
          in
          pkgs.writeText "inputs-locked" (
            assert lib.assertMsg (stale == [ ])
              "inputs-locked failed:\n${lib.concatMapStrings (line: "  ${line}\n") stale}";
            "every group's inputs are locked\n"
          );
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
              # A source copied from a Git worktree carries its `.git` file,
              # which a bare path would make Nix open as a repository.
              nix-unit \
                --show-trace \
                --extra-experimental-features flakes \
                --accept-flake-config \
                ${nixUnitInputArgs} \
                --flake path:${./.}#tests.systems.${system}
              touch "$out"
            '';
        # The closure builds after landing (remoteChecks); evaluating it here
        # still rejects a broken configuration before it lands.
        desktop-primary-evaluation = pkgs.writeText "desktop-primary-evaluation" (
          builtins.unsafeDiscardStringContext "${denAsusPrimary.activationPackage.drvPath}\n"
        );
        den-policy = denPolicyCheck;
        dev-shell = pkgs.runCommand "dev-shell-check" { } ''
          test -x ${jjCi}/bin/ci
          test -x ${pkgs.jujutsu}/bin/jj
          test -x ${pkgs.gh}/bin/gh
          test -x ${pkgs.claude-code}/bin/claude
          test -x ${profileDrift}/bin/profile-drift
          touch "$out"
        '';
        home-manager = homeCheck;
        # nixbot's App manifest asks GitHub for exactly the permissions and
        # events docs/delivery/nixbot.md says nixbot needs, and nixbot-register builds.
        nixbot-app-manifest =
          pkgs.runCommand "nixbot-app-manifest-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/nixbot-manifest.nu} ${./docs/delivery/nixbot.md} ${nixbotRegistration}
              test -x ${nixbotRegister}/bin/nixbot-register
              touch "$out"
            '';
        niri-config =
          pkgs.runCommand "niri-config-check"
            {
              nativeBuildInputs = [ pkgs.niri ];
            }
            ''
              niri validate --config ${
                pkgs.writeText "niri-config.kdl"
                  (import ./niri/binds.nix {
                    inherit lib;
                    honeycomb = inputs.honeycomb.lib;
                  }).config
              }
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
        # jev against a stub server: what reaches the wire, the
        # TYPESAFE_BASE_URL override, and the credential filter.
        nushell-jev =
          pkgs.runCommand "nushell-jev-check"
            {
              nativeBuildInputs = [
                pkgs.nushell
                pkgs.python3
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/jev.nu} ${./jev/jev.nu} ${./jev/questions.nuon}
              touch "$out"
            '';
        # `deploy-reverts causes` with a stub jev, so no request leaves.
        nushell-deploy-reverts =
          pkgs.runCommand "nushell-deploy-reverts-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/deploy-reverts.nu} ${./deploy/reverts.nu} ${./jev/questions.nuon}
              touch "$out"
            '';
        # luvus-deliver's risk classification and approval on a throwaway
        # repository, with a fixture of Den's reach. Nix
        # parses both versions of a changed module to spot comment edits.
        nushell-luvus-deliver =
          pkgs.runCommand "nushell-luvus-deliver-check"
            {
              nativeBuildInputs = [
                pkgs.git
                pkgs.nix
                pkgs.nushell
              ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/luvus-deliver.nu} ${./tools/luvus-deliver.nu}
              touch "$out"
            '';
        # How the staged switch judges each kind of unit a candidate touches:
        # sockets, timers, and targets lack properties services have.
        nushell-staged-switch =
          pkgs.runCommand "nushell-staged-switch-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/staged-switch-units.nu} ${./deploy/switch.nu}
              touch "$out"
            '';
        # system-switch's step tracker, journal/closure-diff parsers, and
        # structured Nushell summary formatter.
        nushell-system-switch =
          pkgs.runCommand "nushell-system-switch-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/system-switch.nu} ${./deploy/system-switch.nu}
              touch "$out"
            '';
        # The Mod+Slash keymap overlay replayed headlessly with `tui debug`.
        nushell-keymap =
          let
            # keymap.nu finds keymap-emoji.nuon beside itself.
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.unions [
                ./niri/keymap.nu
                ./niri/keymap-emoji.nuon
              ];
            };
          in
          pkgs.runCommand "nushell-keymap-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/keymap.nu} ${src}/niri/keymap.nu
              touch "$out"
            '';
        nushell-envrc-nu =
          pkgs.runCommand "nushell-envrc-nu-check"
            {
              nativeBuildInputs = [ pkgs.nushell ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${pkgs.nushell}/bin/nu --no-config-file ${./tests/envrc-nu.nu} ${./nushell/envrc-nu.nu}
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
        # Concurrent Tailscale Serve/Funnel units must serialize updates to
        # /localapi/v0/serve-config and retry on etag mismatch without blocking
        # each other once registered.
        tailscale-serve =
          let
            serveScript = denFlake.nixosConfigurations.homelab.config.dotfiles.tailscale.serve;
          in
          pkgs.runCommand "tailscale-serve-check" { } ''
            set -euo pipefail
            mkdir -p "$TMPDIR/bin" "$TMPDIR/state"

            # Mock tailscale that detects overlapping serve-config writes and
            # fails them with the exact etag mismatch error tailscaled returns.
            cat > "$TMPDIR/bin/mock-tailscale" <<'EOF'
            #!${pkgs.bash}/bin/bash
            set -euo pipefail
            state="$MOCK_STATE_DIR"
            mkdir -p "$state"

            if [ -f "$state/force-etag-once" ]; then
              rm -f "$state/force-etag-once"
              echo "Another client is changing the serve config; please try again." >&2
              echo "sending serve config: Preconditions failed: etag mismatch" >&2
              exit 1
            fi

            if [ "''${1:-}" = "serve" ] && [ "''${2:-}" = "fail-hard" ]; then
              echo "invalid serve target" >&2
              exit 2
            fi

            # Detect concurrent serve-config mutation: mkdir is atomic.
            if ! mkdir "$state/inflight" 2>/dev/null; then
              echo "Another client is changing the serve config; please try again." >&2
              echo "sending serve config: Preconditions failed: etag mismatch" >&2
              exit 1
            fi
            sleep 0.05
            rmdir "$state/inflight"

            for arg in "$@"; do
              case "$arg" in
                --bg | --bg=true | off | status | reset)
                  echo "ok:$*" >> "$state/short.log"
                  exit 0
                  ;;
              esac
            done

            echo "Available within your tailnet:"
            echo "https://homelab.example.ts.net/"
            echo "Press Ctrl+C to exit."
            echo "started:$*" >> "$state/fg.log"
            trap 'echo "stopped:$*" >> "$state/fg.log"; exit 0' TERM INT
            while true; do sleep 1; done
            EOF
            chmod +x "$TMPDIR/bin/mock-tailscale"

            export TAILSCALE_BIN="$TMPDIR/bin/mock-tailscale"
            export TAILSCALE_SERVE_LOCK="$TMPDIR/serve.lock"
            export TAILSCALE_SERVE_RETRY_DELAY="0.05"
            export MOCK_STATE_DIR="$TMPDIR/state"
            : > "$MOCK_STATE_DIR/fg.log"

            # 1. Eight concurrent foreground serve units serialize registration
            #    with zero etag collisions, stay up concurrently, and stop cleanly.
            pids=()
            for i in 1 2 3 4 5 6 7 8; do
              ${serveScript} serve --https="$((7440 + i))" "http://127.0.0.1:$((8000 + i))" >"$TMPDIR/fg-$i.log" 2>&1 &
              pids+=($!)
            done

            deadline=$((SECONDS + 15))
            while [ "$(wc -l < "$MOCK_STATE_DIR/fg.log" 2>/dev/null || echo 0)" -lt 8 ]; do
              if [ "$SECONDS" -ge "$deadline" ]; then
                echo "timed out waiting for 8 foreground units" >&2
                exit 1
              fi
              sleep 0.05
            done

            for pid in "''${pids[@]}"; do
              kill -0 "$pid"
            done
            for pid in "''${pids[@]}"; do
              kill -TERM "$pid"
            done
            for pid in "''${pids[@]}"; do
              wait "$pid"
            done
            test "$(grep -c '^stopped:' "$MOCK_STATE_DIR/fg.log")" -eq 8

            # 2. Forced etag mismatch on foreground startup retries and succeeds.
            touch "$MOCK_STATE_DIR/force-etag-once"
            ${serveScript} serve --https=7450 http://127.0.0.1:8050 >"$TMPDIR/retry-fg.log" 2>&1 &
            rpid=$!
            deadline=$((SECONDS + 10))
            while ! grep -q '^started:serve --https=7450' "$MOCK_STATE_DIR/fg.log"; do
              if [ "$SECONDS" -ge "$deadline" ]; then
                echo "foreground retry did not succeed" >&2
                cat "$TMPDIR/retry-fg.log" >&2
                exit 1
              fi
              sleep 0.05
            done
            kill -TERM "$rpid"
            wait "$rpid"

            # 3. Concurrent short-lived (--bg and off) commands serialize and retry.
            touch "$MOCK_STATE_DIR/force-etag-once"
            spids=()
            for i in 1 2 3 4; do
              ${serveScript} funnel --bg --https=8443 "$((8010 + i))" &
              spids+=($!)
              ${serveScript} serve --https="$((7440 + i))" off &
              spids+=($!)
            done
            for pid in "''${spids[@]}"; do
              wait "$pid"
            done
            test "$(wc -l < "$MOCK_STATE_DIR/short.log")" -eq 8

            # 4. Real errors are not retried and preserve exit code.
            rc=0
            ${serveScript} serve fail-hard >/dev/null 2>&1 || rc=$?
            test "$rc" -eq 2

            touch "$out"
          '';

        # TLC explores every state of the staged switch's bounded model, once
        # with activation able to outlast the dead-man's grace period and once
        # with the timer firing only after its run has died.
        staged-switch-model =
          pkgs.runCommand "staged-switch-model-check" { nativeBuildInputs = [ pkgs.tlaplus ]; }
            ''
              cp ${./deploy/StagedSwitch.tla} StagedSwitch.tla
              cp ${./deploy/StagedSwitch.cfg} StagedSwitch.cfg
              cp ${./deploy/StagedSwitchOnTime.cfg} StagedSwitchOnTime.cfg
              for cfg in StagedSwitch StagedSwitchOnTime; do
                tlc -workers auto -metadir "$TMPDIR/$cfg" -config "$cfg.cfg" StagedSwitch.tla
              done
              touch "$out"
            '';
        whitespace =
          let
            # Leave out what the globs below skip, so ignored state such as
            # .direnv does not change the check's input.
            src = lib.fileset.toSource {
              root = ./.;
              fileset = lib.fileset.difference ./. (
                lib.fileset.unions (
                  map lib.fileset.maybeMissing [
                    ./.git
                    ./.jj
                    ./.direnv
                    ./packages
                    ./result
                  ]
                )
              );
            };
          in
          pkgs.runCommand "whitespace-check"
            {
              nativeBuildInputs = [ pkgs.ripgrep ];
            }
            ''
              cd ${src}
              matches="$(${pkgs.ripgrep}/bin/rg \
                --hidden \
                --glob '!.git/**' \
                --glob '!.jj/**' \
                --glob '!.direnv/**' \
                --glob '!packages/**' \
                --glob '!**/node_modules/**' \
                --glob '!result*' \
                --glob '!*.patch' \
                '[[:blank:]]$' . || true)"
              if [ -n "$matches" ]; then
                printf '%s\n' "$matches"
                exit 1
              fi
              touch "$out"
            '';
      }
      // denHostEvaluationChecks
      // denConfigTestChecks;

      # What the luvus gate and nixbot build (nixbot.toml's `attribute`): the
      # checks, plus the system and home asus switches to right after each
      # delivery. Building them before a landing turns a closure that fails to
      # build into a failed gate instead of a failed switch, and leaves them in
      # homelab's cache and asus's store, so the switch only activates. checks
      # alone stays light enough for GitHub's runners.
      gateChecks.${system} = inputs.self.checks.${system} // {
        desktop-system = denAsus.config.system.build.toplevel;
        desktop-home = denAsusHome.activationPackage;
      };

      # Checks that report without gating a landing: GitHub Actions' nix-ci
      # workflow builds them after each push, and the luvus gate and nixbot
      # leave them out.
      # They cover disposable hosts, Clan's machines against the systems they
      # deploy, homelab with modules it has not adopted yet, the staged
      # switch's revert in a VM, and Bombadil's exploration of Fieldwork.
      # Bombadil explores Fieldwork, a prototype whose bridge answers some
      # requests with 4xx by design, so its findings report here first; the
      # keymap checks of programs that do not follow the keymap rules yet,
      # such as jjui, report here too.
      remoteChecks.${system} =
        remoteHostEvaluationChecks
        // clanMachineChecks
        // import ./xr-workbench/bombadil-check.nix { inherit lib pkgs; }
        // import ./modules/tooling/keymap-checks/remote.nix { inherit inputs lib pkgs; }
        // {
          # TLC over every three-change graph takes about twelve minutes.
          jj-graph-model-exhaustive = jjGraph.exhaustive;
          deploy-revert = import ./tests/deploy-revert.nix { inherit pkgs; };
          marimohub-homelab-evaluation = marimohubHomelabEvaluationCheck;
          discord-digest-homelab-evaluation = discordDigestHomelabEvaluationCheck;
          nixbot-homelab-evaluation = nixbotHomelabEvaluationCheck;
          # GitHub builds these closures after each push too. asus's system
          # and full home also gate a landing, through gateChecks.
          desktop-primary = denAsusPrimary.activationPackage;
          desktop-system = denAsus.config.system.build.toplevel;
          headless-system = denFlake.nixosConfigurations.asus-headless.config.system.build.toplevel;
        };
    };
  nixConfig = {
    extra-substituters = [
      "https://cache.flakehub.com/"
    ];
    trusted-users = [ "schlich" ];
  };
}
