{
  config,
  lib,
  pkgs,
  ...
}:

# Keeps the ci flake input on ci's latest release. An hourly timer compares
# the ci revision main's flake.lock pins with the newest release tag on the
# GitHub mirror; when the release is ahead and no bump is open, it starts the
# ci-input-update workspace, runs `nix flake update ci`, declares the change
# `behavior`, dispatches it, and sends a desktop notification. It never lands:
# `ci land` and `ci park` from that workspace stay a deliberate step, since a
# ci update reaches every host and homelab deploys each landing of main.
# Workstations only, because impact declarations live in the ci log of the
# machine that lands them. `ci-input-watch` shows where things stand.

let
  ciInputWatch = pkgs.writeShellApplication {
    name = "ci-input-watch";
    text = ''
      export CI_INPUT_WATCH_REPO="''${CI_INPUT_WATCH_REPO:-$HOME/dotfiles}"
      export CI_INPUT_WATCH_NOTIFY=${pkgs.libnotify}/bin/notify-send
      exec ${lib.getExe pkgs.nushell} --no-config-file ${../../tools/ci-input-watch.nu} "$@"
    '';
    meta.description = "Open and dispatch a ci flake input update when ci publishes a release";
  };
in
{
  home.packages = [ ciInputWatch ];

  dotfiles.tooling.checks.ci-input-watch =
    pkgs.runCommand "ci-input-watch-check" { nativeBuildInputs = [ pkgs.nushell ]; }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        nu --no-config-file ${../../tests/ci-input-watch.nu} ${../../tools/ci-input-watch.nu}
        touch "$out"
      '';

  systemd.user.services.ci-input-watch = {
    Unit = {
      Description = "Dispatch a ci flake input update for a new ci release";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe ciInputWatch} check";
      # Dispatch runs preflight, which takes several minutes.
      TimeoutStartSec = "30min";
      Environment = [
        # git lists the mirror's tags and gh compares them, carrying the
        # GitHub login; ci, jj and nix come from the user and system profiles.
        "PATH=${
          lib.makeBinPath [
            pkgs.git
            config.programs.gh.package
          ]
        }:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
        # Dispatch pushes to Tangled over SSH.
        "SSH_AUTH_SOCK=%t/gcr/ssh"
      ];
    };
  };
  systemd.user.timers.ci-input-watch = {
    Unit.Description = "Check hourly for a ci release main does not pin";
    Timer = {
      OnCalendar = "hourly";
      # Catch up after the laptop was off or asleep at the scheduled time.
      Persistent = true;
      RandomizedDelaySec = "5min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
