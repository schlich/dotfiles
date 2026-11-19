{
  config,
  inputs,
  lib,
  options,
  pkgs,
  ...
}:

# Packages this home takes from somewhere other than nixpkgs, builds itself,
# or overrides, because nixpkgs lags, lacks, or ships them without something
# this configuration needs. Declare each entry beside its workaround, so
# removing the workaround removes the watch. Then nothing is maintained by
# hand:
#
# - A flake check (nixpkgs-watch-coverage) fails on a workaround no entry
#   covers: a package from a flake input, a local build of upstream source,
#   or an overrideAttrs. `nixpkgs-watch coverage DIR FILE` runs it by hand.
# - Evaluation warns once the locked nixpkgs ships the package (at least
#   `version`, when set), so the build after `nix flake update nixpkgs` says
#   the workaround can go.
# - A daily timer asks npr which nixpkgs pull requests for each package are
#   open or have reached the unstable channels, asks GitHub whether an
#   entry's upstream `fix` is in the release nixpkgs ships, asks the public
#   binary caches whether upstream's own build of an `input` is
#   substitutable, and looks for the upstream `repo` on FlakeHub. It sends a
#   desktop notification when that changes and queues a luvus task for each
#   workaround that can go. `nixpkgs-watch` shows the last report.

let
  inherit (lib) mkOption types;
  cfg = config.dotfiles.nixpkgsWatch;
  system = pkgs.stdenv.hostPlatform.system;
  npr = inputs.npr.packages.${system}.default;
  luvus = import ../programs/luvus-package.nix { inherit inputs lib pkgs; };
  marimohub = import ../tooling/knowledge/marimohub-package.nix { inherit lib pkgs; };

  lock = lib.importJSON ../../flake.lock;
  # The lock node of a direct flake input; null for one that follows another.
  lockNode =
    name:
    let
      key = lock.nodes.${lock.root}.inputs.${name} or null;
    in
    if builtins.isString key then lock.nodes.${key} else null;
  # A flake reference to exactly the locked revision, which `nix eval`
  # evaluates with upstream's own lock file.
  lockedRef =
    locked:
    if locked.type == "github" then
      "github:${locked.owner}/${locked.repo}/${locked.rev}"
    else if locked.type == "tarball" then
      locked.url
    else if locked.type == "git" then
      "git+${locked.url}?rev=${locked.rev}"
    else
      null;

  # The files that declare each entry, relative to the repository, for the
  # tasks the timer queues.
  declaredIn = lib.foldl' (
    acc: def:
    let
      file = lib.last (lib.splitString "-source/" (toString def.file));
    in
    lib.foldl' (acc: name: acc // { ${name} = (acc.${name} or [ ]) ++ [ file ]; }) acc (
      lib.optionals (builtins.isAttrs def.value) (lib.attrNames def.value)
    )
  ) { } options.dotfiles.nixpkgsWatch.definitionsWithLocations;

  status = lib.mapAttrs (
    name: entry:
    let
      available = builtins.hasAttr entry.package pkgs;
      nixpkgs = if available then pkgs.${entry.package}.version or null else null;
      node = if entry.input == null then null else lockNode entry.input;
      original = if node == null then { } else node.original;
    in
    {
      inherit (entry)
        package
        version
        reason
        fix
        input
        attr
        ;
      inherit name nixpkgs system;
      repo =
        if entry.repo != null then
          entry.repo
        else if (original.type or null) == "github" then
          "${original.owner}/${original.repo}"
        else
          null;
      locked = if node == null then null else lockedRef node.locked;
      rev = if node == null then null else node.locked.rev or null;
      # The input builds against this flake's nixpkgs, so its outputs differ
      # from the ones upstream builds and caches.
      follows = node != null && builtins.isList (node.inputs.nixpkgs or null);
      onFlakehub = lib.hasPrefix "https://flakehub.com/" (original.url or "");
      files = declaredIn.${name} or [ ];
      # An upstream `fix` without a `version` is the daily check's to judge:
      # nixpkgs shipping the package says nothing about the override.
      ready =
        available
        && (
          if entry.version != null then
            nixpkgs != null && lib.versionAtLeast nixpkgs entry.version
          else
            entry.fix == null
        );
    }
  ) cfg;

  # Judges the pull requests that only mention a watched package.
  jev = import ../../jev/package.nix { inherit pkgs; };

  nixpkgsWatch = pkgs.writeShellApplication {
    name = "nixpkgs-watch";
    text = ''
      export NIXPKGS_WATCH_STATUS=${pkgs.writeText "nixpkgs-watch.json" (builtins.toJSON status)}
      export NIXPKGS_WATCH_NPR=${npr}/bin/npr
      export NIXPKGS_WATCH_NOTIFY=${pkgs.libnotify}/bin/notify-send
      export NIXPKGS_WATCH_JEV=${jev}/bin/jev
      export NIXPKGS_WATCH_QUESTIONS=${../../jev/questions.nuon}
      export NIXPKGS_WATCH_GH=${lib.getExe config.programs.gh.package}
      export NIXPKGS_WATCH_CURL=${lib.getExe pkgs.curl}
      # The system's own nix, whose configuration carries FlakeHub's login.
      export NIXPKGS_WATCH_NIX=nix
      export NIXPKGS_WATCH_LUVUS=${luvus}/bin/luvus
      export NIXPKGS_WATCH_REPO=${config.home.homeDirectory}/dotfiles
      export NIXPKGS_WATCH_GATE=${lib.escapeShellArg "nix-fast-build --skip-cached --no-nom --flake path:.#checks.x86_64-linux"}
      exec ${lib.getExe pkgs.nushell} --no-config-file ${../../tools/nixpkgs-watch.nu} "$@"
    '';
    meta.description = "Report when nixpkgs or upstream catches up with this home's workarounds";
  };

  # Every Nix file of the repository, but not the other checkouts in it.
  coverageSource = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.difference (lib.fileset.fileFilter (file: file.hasExt "nix") ../..) (
      lib.fileset.unions (
        map lib.fileset.maybeMissing [
          ../../.jj-workspaces
          ../../.claude
          ../../templates
        ]
      )
    );
  };
  coverageDeclared = pkgs.writeText "nixpkgs-watch-declared.json" (
    builtins.toJSON {
      entries = lib.mapAttrs (_: entry: { inherit (entry) package input; }) cfg;
      exempt = config.dotfiles.nixpkgsWatchExempt;
    }
  );
in
{
  options.dotfiles.nixpkgsWatch = mkOption {
    type = types.attrsOf (
      types.submodule (
        { name, ... }:
        {
          options = {
            package = mkOption {
              type = types.str;
              default = name;
              description = "nixpkgs attribute name, which is also npr's search term.";
            };
            version = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = ''
                Version the workaround provides. nixpkgs has caught up once it
                ships at least this; null means once it ships the package at
                all, or, with `fix`, once its release contains the fix.
              '';
            };
            fix = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "https://github.com/OWNER/REPO/pull/123";
              description = ''
                GitHub pull request or commit whose release ends the
                workaround, for an override that patches a package or turns
                on what nixpkgs' build leaves out. The daily check reports it
                merged, then asks whether the release nixpkgs ships contains
                it, or for an `input`, the locked revision.
              '';
            };
            input = mkOption {
              type = types.nullOr types.str;
              default = if inputs ? ${name} then name else null;
              defaultText = "the entry's name, when the flake has an input of that name";
              description = ''
                Flake input the workaround takes the package from. The entry
                covers that input's packages in the coverage check, and when
                the input follows this flake's nixpkgs, the daily check asks
                whether upstream's own build is in cache.nixos.org, FlakeHub
                Cache, or a binary cache upstream's flake.nix declares.
              '';
            };
            attr = mkOption {
              type = types.str;
              default = "default";
              description = "The input's package under `packages.<system>`, for the cache check.";
            };
            repo = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "OWNER/REPO";
              description = ''
                Upstream's GitHub repository, for a package built here from
                source. The daily check reports when it publishes on FlakeHub
                or gains a flake.nix. An `input` from GitHub sets it.
              '';
            };
            reason = mkOption {
              type = types.str;
              description = "The workaround, and what to remove once nixpkgs catches up.";
            };
          };
        }
      )
    );
    default = { };
    description = "Packages to drop a workaround for once nixpkgs or upstream catches up.";
  };

  options.dotfiles.nixpkgsWatchExempt = mkOption {
    type = types.attrsOf types.str;
    default = { };
    example = {
      my-tool = "the user's own project, which nixpkgs will not ship";
    };
    description = ''
      Flake inputs whose packages are not workarounds, each with the reason,
      such as the user's own projects. The coverage check accepts their
      packages without a watch entry.
    '';
  };

  config = lib.mkMerge [
    {
      # For checking a package by hand: `npr <attribute>`.
      home.packages = [ npr ];

      dotfiles.nixpkgsWatch.npr.reason = "replace the npr input's package in modules/home/nixpkgs-watch.nix with pkgs.npr and drop the npr input";

      # A workaround of the systems, which share this home's nixpkgs.
      dotfiles.nixpkgsWatch.marimohub = {
        inherit (marimohub) version;
        repo = "marimo-team/marimohub";
        reason = "replace modules/tooling/knowledge/marimohub-package.nix with pkgs.marimohub in flake.nix and modules/nixos/workbench-hub.nix";
      };

      dotfiles.nixpkgsWatchExempt = {
        ci = "the user's own trunk workflow, which homelab's cache serves";
        fieldnotes = "the user's own dashboard";
        tangled-dash = "the user's own Tangled dashboard";
        continuum-ide = "the user's own fork of T3 Code";
        clan-core = "clan-cli has to match the clan-core modules this flake imports";
        nix-grpc-store = "the store plugin builds against this system's own Nix";
      };

      dotfiles.tooling.checks.nixpkgs-watch =
        pkgs.runCommand "nixpkgs-watch-check" { nativeBuildInputs = [ pkgs.nushell ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            nu --no-config-file ${../../tests/nixpkgs-watch.nu} ${../../tools/nixpkgs-watch.nu} ${../../jev/questions.nuon}
            touch "$out"
          '';

      dotfiles.tooling.checks.nixpkgs-watch-coverage =
        pkgs.runCommand "nixpkgs-watch-coverage" { nativeBuildInputs = [ pkgs.nushell ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            nu --no-config-file ${../../tools/nixpkgs-watch.nu} coverage ${coverageSource} ${coverageDeclared}
            touch "$out"
          '';
    }

    (lib.mkIf (cfg != { }) {
      warnings = lib.mapAttrsToList (
        _: entry:
        "nixpkgs now ships ${entry.package} ${toString entry.nixpkgs}; drop the workaround: ${entry.reason}"
      ) (lib.filterAttrs (_: entry: entry.ready) status);

      home.packages = [ nixpkgsWatch ];

      systemd.user.services.nixpkgs-watch = {
        Unit.Description = "Check nixpkgs and upstream for worked-around packages";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe nixpkgsWatch} check --notify --queue-tasks";
          Environment = [
            # npr searches through gh, which carries the GitHub login; the
            # cache check runs the system's nix.
            "PATH=${lib.makeBinPath [ config.programs.gh.package ]}:/run/current-system/sw/bin"
          ];
          # Evaluating an input with upstream's own lock fetches upstream's
          # nixpkgs the first time.
          TimeoutStartSec = "30min";
        };
      };
      systemd.user.timers.nixpkgs-watch = {
        Unit.Description = "Check nixpkgs and upstream for worked-around packages daily";
        Timer = {
          OnCalendar = "daily";
          # Catch up after the laptop was off or asleep at the scheduled time.
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
        Install.WantedBy = [ "timers.target" ];
      };
    })
  ];
}
