{
  config,
  lib,
  pkgs,
  ...
}:

# Keeps the ci flake input on ci's latest release. `ci land` records every
# release it tags in the ci log, so a path unit on the log wakes the service,
# which reads what was appended since its last run. When that holds a
# release, it compares the ci revision main's flake.lock pins with the newest
# release tag on the GitHub mirror; when the release is ahead and no bump is
# open, it starts the
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
      # ci writes its log in bursts, a run each write; systemd's default limit
      # of five starts in ten seconds failed the service and with it the path
      # unit (2026-10-19), so the watch stopped. The pause below paces runs
      # instead.
      StartLimitIntervalSec = 0;
    };
    Service = {
      Type = "oneshot";
      # Debounce: writes during the pause start no further run, and the run
      # after it reads all of them from the saved offset.
      ExecStartPre = "${pkgs.coreutils}/bin/sleep 10";
      ExecStart = "${lib.getExe ciInputWatch} on-log";
      # Dispatch runs preflight, which takes several minutes.
      TimeoutStartSec = "30min";
      Environment = [
        # git lists the mirror's tags and gh compares them, carrying the
        # GitHub login; tail reads the log's new bytes; ci, jj and nix come
        # from the standalone home's profile, where home.packages install,
        # and the system profile. Without ~/.nix-profile no run found jj
        # (2026-10-19).
        "PATH=${
          lib.makeBinPath [
            pkgs.git
            pkgs.coreutils
            config.programs.gh.package
          ]
        }:%h/.nix-profile/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
        # Dispatch pushes to GitHub over HTTPS through gh's credentials;
        # landing also mirrors main to Tangled over SSH.
        "SSH_AUTH_SOCK=%t/gcr/ssh"
      ];
    };
  };
  # %S is $XDG_STATE_HOME for the user manager, where ci keeps its log. A
  # write while the service runs starts no run of its own; the next run reads
  # it from the saved offset, so none is lost while ci keeps writing.
  systemd.user.paths.ci-input-watch = {
    Unit.Description = "Watch the ci log for a release main does not pin";
    Path.PathModified = "%S/ci/log.otlp.jsonl";
    Install.WantedBy = [ "paths.target" ];
  };
}
