{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# Packages this home takes from somewhere other than nixpkgs, or builds itself,
# because nixpkgs lags or lacks them. Declare each entry beside its workaround,
# so removing the workaround removes the watch. Two signals then say when
# nixpkgs has caught up, with nothing to maintain by hand:
#
# - Evaluation warns once the locked nixpkgs ships the package (at least
#   `version`, when set), so the build after `nix flake update nixpkgs` says
#   the workaround can go.
# - A daily timer asks npr which nixpkgs pull requests for each package are
#   open or have reached the unstable channels, and sends a desktop
#   notification when that changes. `nixpkgs-watch` shows the last report.

let
  inherit (lib) mkOption types;
  cfg = config.dotfiles.nixpkgsWatch;
  npr = inputs.npr.packages.${pkgs.stdenv.hostPlatform.system}.default;

  status = lib.mapAttrs (
    _: entry:
    let
      available = builtins.hasAttr entry.package pkgs;
      nixpkgs = if available then pkgs.${entry.package}.version or null else null;
    in
    {
      inherit (entry) package version reason;
      inherit nixpkgs;
      ready =
        available
        && (entry.version == null || (nixpkgs != null && lib.versionAtLeast nixpkgs entry.version));
    }
  ) cfg;

  nixpkgsWatch = pkgs.writeShellApplication {
    name = "nixpkgs-watch";
    text = ''
      export NIXPKGS_WATCH_STATUS=${pkgs.writeText "nixpkgs-watch.json" (builtins.toJSON status)}
      export NIXPKGS_WATCH_NPR=${npr}/bin/npr
      export NIXPKGS_WATCH_NOTIFY=${pkgs.libnotify}/bin/notify-send
      exec ${lib.getExe pkgs.nushell} --no-config-file ${../../tools/nixpkgs-watch.nu} "$@"
    '';
    meta.description = "Report nixpkgs pull requests for the packages this home works around";
  };
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
                ships at least this; null means once it ships the package at all.
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
    description = "Packages to drop a workaround for once nixpkgs catches up.";
  };

  config = lib.mkMerge [
    {
      # For checking a package by hand: `npr <attribute>`.
      home.packages = [ npr ];

      dotfiles.tooling.checks.nixpkgs-watch =
        pkgs.runCommand "nixpkgs-watch-check" { nativeBuildInputs = [ pkgs.nushell ]; }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            nu --no-config-file ${../../tests/nixpkgs-watch.nu} ${../../tools/nixpkgs-watch.nu}
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
        Unit.Description = "Check nixpkgs pull requests for worked-around packages";
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe nixpkgsWatch} check --notify";
          # npr searches through gh, which carries the GitHub login.
          Environment = [
            "PATH=${lib.makeBinPath [ config.programs.gh.package ]}"
          ];
          TimeoutStartSec = "5min";
        };
      };
      systemd.user.timers.nixpkgs-watch = {
        Unit.Description = "Check nixpkgs pull requests for worked-around packages daily";
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
