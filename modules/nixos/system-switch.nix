{
  config,
  lib,
  options,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.deploy;
  unit = "nixos-switch-main";
  stateDir = "/var/lib/${unit}";
  host = config.networking.hostName;
  # Only `ci land` moves main, after its landing checks, so this never
  # applies a working copy or an unreviewed change. The staged switch in
  # deploy/switch.nu catches what those checks cannot see on a running host.
  repo = "https://tangled.org/schlich.tngl.sh/dotfiles";
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };

  probeType = lib.types.submodule {
    options = {
      command = lib.mkOption {
        type = lib.types.path;
        description = "Executable that exits 0 while the host is healthy.";
      };
      timeout = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10;
        description = "Seconds before the probe counts as failed.";
      };
      latency = lib.mkOption {
        type = lib.types.nullOr lib.types.number;
        default = null;
        description = "Seconds the probe may take before a slow answer fails it too.";
      };
    };
  };

  probe = name: text: pkgs.writeShellScript "health-${name}" text;
  # The candidate's own programs, which match the daemons and configuration
  # it activated; the previous system's niri may not accept a newer config.
  active = "/run/current-system/sw/bin";
  # The probes `policy.healthChecks` in den/inventory.nix can name. Each
  # exists only where its service does, so naming a missing one fails
  # evaluation.
  builtinProbes =
    lib.optionalAttrs config.services.openssh.enable {
      ssh = {
        command = probe "ssh" ''
          keys="$(${pkgs.openssh}/bin/ssh-keyscan -T 5 -p ${toString (builtins.head config.services.openssh.ports)} 127.0.0.1 2>/dev/null)"
          test -n "$keys"
        '';
        latency = 3;
      };
    }
    // lib.optionalAttrs config.services.tailscale.enable {
      tailscale = {
        command = probe "tailscale" ''
          ${active}/tailscale status --json \
            | ${pkgs.jq}/bin/jq --exit-status '.BackendState == "Running"' >/dev/null
        '';
        latency = 5;
      };
    }
    // lib.optionalAttrs config.programs.niri.enable {
      niri-config.command = probe "niri-config" ''
        ${active}/niri validate --config /etc/niri/config.kdl
      '';
    }
    // lib.optionalAttrs (options ? home-manager) {
      home-manager-nixos.command = probe "home-manager-nixos" (
        lib.concatMapStrings (user: ''
          if ${config.systemd.package}/bin/systemctl is-failed --quiet home-manager-${user}.service; then
            echo "home-manager-${user}.service failed"
            exit 1
          fi
        '') (builtins.attrNames config.home-manager.users)
      );
    };

  checks = lib.unique cfg.healthChecks;
  missing = lib.filter (name: !(cfg.probes ? ${name})) checks;

  # The running system's settings judge a candidate, so these are what the
  # switch script reads, not the candidate's.
  deployConfig = pkgs.writeText "${unit}.json" (
    builtins.toJSON {
      inherit host repo;
      state = stateDir;
      inherit (cfg) watch journal restarts;
      probes = map (name: {
        inherit name;
        inherit (cfg.probes.${name}) timeout latency;
        command = "${cfg.probes.${name}.command}";
      }) (lib.subtractLists missing checks);
    }
  );

  # Servers lack the nushellWith overlay behind writeNuScriptBin. The
  # dead-man timer's transient unit gets only this PATH.
  switchMain = wrapWithConfig {
    package = pkgs.writers.writeNuBin unit (builtins.readFile ../../deploy/switch.nu);
    env = {
      DEPLOY_CONFIG = "${deployConfig}";
      PATH = lib.makeBinPath [
        config.nix.package
        config.systemd.package
        pkgs.coreutils
        pkgs.git
      ];
    };
  };
  deployReverts = pkgs.writers.writeNuBin "deploy-reverts" (
    builtins.readFile ../../deploy/reverts.nu
  );

  # The manual and the automatic switch share one lock, so they never stage
  # two systems at once; the automatic one gives way. flock takes its
  # options before the lock file.
  lock = flags: "${pkgs.util-linux}/bin/flock ${flags}${stateDir}/lock";
  switchService = {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    # The switch runs inside this unit, so a configuration that changes it
    # must not stop it mid-switch: the new definition applies on the next run.
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = unit;
      StateDirectoryMode = "0755";
      UMask = "0022";
    };
  };

  # Start the unit and show its output and result. The journal is read
  # through the user manager so this also works inside the Claude desktop
  # app's sandbox. It lives here, not in Home Manager, so hosts without Home
  # Manager (homelab) get it too.
  systemSwitch = pkgs.writers.writeNuBin "system-switch" ''
    # Apply the NixOS configuration on Tangled's main without sudo: start
    # the root ${unit} unit, then show its output and result.
    def main [] {
      let unit = "${unit}.service"
      let bin = "/run/current-system/sw/bin"
      let since = (date now | format date "%Y-%m-%d %H:%M:%S")
      print $"Switching to main through ($unit); a new system is watched for ${toString cfg.watch.duration}s before it becomes the boot default..."
      let result = (^$"($bin)/systemctl" start $unit | complete)
      let log = (
        ^$"($bin)/systemd-run" --user --pipe --wait --collect --quiet
          $"($bin)/journalctl" --unit $unit --since $since --no-pager --output cat
        | complete
      )
      print $log.stdout
      let state = "${stateDir}/last.nuon"
      if ($state | path exists) {
        let last = (open $state)
        print $last
        if ($last.report? | is-not-empty) {
          print $"Revert report: ($last.report)"
        }
      }
      let failed = (^$"($bin)/systemctl" --failed --no-legend --plain | complete | get stdout | str trim)
      if ($failed | is-not-empty) {
        print $"Failed units:\n($failed)"
      }
      if $result.exit_code != 0 {
        error make { msg: $"($unit) failed: ($result.stderr | str trim)" }
      }
    }
  '';
in

{
  options.dotfiles.deploy = {
    autoDeploy = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this host stages each new landing of Tangled's main on its
        own, as policy.autoDeploy in den/inventory.nix asks.
      '';
    };
    poll = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "How long an auto-deploying host waits between looks at main.";
    };
    healthChecks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Probes a staged switch runs beside its built-in unit, journal, and
        restart checks, from policy.healthChecks in den/inventory.nix.
      '';
    };
    probes = lib.mkOption {
      type = lib.types.attrsOf probeType;
      default = { };
      description = "Health probes by name that healthChecks may select.";
    };
    watch = {
      duration = lib.mkOption {
        type = lib.types.ints.positive;
        default = 180;
        description = "Seconds a staged system must stay healthy before it becomes the boot default.";
      };
      interval = lib.mkOption {
        type = lib.types.ints.positive;
        default = 15;
        description = "Seconds between health samples.";
      };
      failures = lib.mkOption {
        type = lib.types.ints.positive;
        default = 3;
        description = "Consecutive failed samples of one check that revert the switch.";
      };
      grace = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300;
        description = ''
          Seconds past the watch window after which the dead-man timer
          reverts a staged switch whose watch never decided.
        '';
      };
    };
    journal = {
      minErrors = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 25;
        description = "Error-priority journal lines a watch always tolerates.";
      };
      factor = lib.mkOption {
        type = lib.types.number;
        default = 3;
        description = "How many times the pre-switch journal error rate a watch tolerates.";
      };
    };
    restarts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Automatic restarts of one unit during the watch that count as a restart loop.";
    };
    notify = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the desktop session announces reverts here and on the canaries.";
      };
      sources = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "ssh destinations of canaries whose reverts this workstation announces.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = missing == [ ];
        message = "${host}: policy.healthChecks names probes this host lacks: ${lib.concatStringsSep ", " missing}. Known: ${lib.concatStringsSep ", " (builtins.attrNames cfg.probes)}.";
      }
    ];

    dotfiles.deploy.probes = builtinProbes;

    environment.systemPackages = [
      systemSwitch
      switchMain
      deployReverts
    ];

    # Apply landed main without sudo: the system-switch command starts this
    # unit over D-Bus, which also works where sudo cannot, such as inside the
    # Claude desktop app's sandbox.
    systemd.services.${unit} = switchService // {
      description = "Switch to the NixOS configuration on Tangled's main";
      serviceConfig = switchService.serviceConfig // {
        ExecStart = "${lock ""} ${switchMain}/bin/${unit}";
      };
    };

    # A canary stages each landing by itself; a revision it already deployed
    # or rejected waits for main to move. It skips a turn while a manual
    # switch holds the lock.
    systemd.services."${unit}-auto" = lib.mkIf cfg.autoDeploy (
      switchService
      // {
        description = "Stage each new landing of Tangled's main on this canary";
        serviceConfig = switchService.serviceConfig // {
          ExecStart = "${lock "--nonblock --conflict-exit-code 0 "} ${switchMain}/bin/${unit} --auto";
        };
      }
    );
    systemd.timers."${unit}-auto" = lib.mkIf cfg.autoDeploy {
      description = "Look for a new landing of Tangled's main";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitInactiveSec = cfg.poll;
        RandomizedDelaySec = "30s";
      };
    };

    # Announce each revert, here or on a canary, once, and offer to open an
    # agent on its report, as boot-postmortem-notify does for crashes.
    systemd.user.services.deploy-revert-notify = lib.mkIf cfg.notify.enable {
      description = "Announce staged switches that reverted here or on a canary";
      after = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      # niri comes from the system; `ssh`, `terminal`, `ai`, and `editor`
      # from the profile.
      environment.PATH = lib.mkForce "${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.libnotify
        ]
      }:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${deployReverts}/bin/deploy-reverts notify ${lib.escapeShellArgs (lib.unique cfg.notify.sources)}";
      };
    };
    systemd.user.timers.deploy-revert-notify = lib.mkIf cfg.notify.enable {
      description = "Look for new deploy reverts";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      timerConfig = {
        OnActiveSec = "1min";
        OnUnitInactiveSec = "5min";
      };
    };

    # schlich may start that one unit from an active local session, and any
    # wheel member may start it from a remote session such as ssh to homelab,
    # without a password. Stopping, editing, or starting any other unit still
    # asks.
    security.polkit.extraConfig = ''
      polkit.addRule(function (action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "${unit}.service" &&
            action.lookup("verb") == "start" &&
            ((subject.user == "schlich" && subject.local && subject.active) ||
             subject.isInGroup("wheel"))) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
