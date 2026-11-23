# Tests on the finished systems: what each host's evaluated configuration
# makes of its inventory facts, where tests.nix checks the facts themselves.
# They only evaluate. flake.nix runs each group as its own check
# (den-config-tests-NAME) so one evaluator holds one system at a time, and
# sends a disposable host's group to remoteChecks with its evaluation.
{
  lib,
  hosts,
  nixosConfigurations,
  homeConfigurations,
}:
let
  builder = import ../hosts/homelab/builder.nix;
  cache = import ../hosts/homelab/cache.nix;
  # Where the fleet should find homelab, from the inventory alone.
  homelabFqdn = "homelab.${hosts.homelab.network.tailnet}";

  # A staged switch watches the probes its policy names, and system-switch.nix
  # defines a probe only where its service runs. Its assertion fires when the
  # system builds; this fires when it evaluates.
  deployTests = name: config: {
    testHealthChecksFollowPolicyAndHaveProbes = {
      expr = {
        checks = config.dotfiles.deploy.healthChecks;
        missing = lib.subtractLists (builtins.attrNames config.dotfiles.deploy.probes) config.dotfiles.deploy.healthChecks;
      };
      expected = {
        checks = hosts.${name}.policy.healthChecks;
        missing = [ ];
      };
    };
  };

  # Every remote host but homelab, which serves them, fetches from homelab's
  # cache and builds on it, both at its tailnet name.
  remoteClientTests = config: {
    testUsesHomelabCacheAndBuilderOnTheTailnet = {
      expr = {
        fqdn = config.dotfiles.fleet.hosts.homelab.fqdn;
        substituter = builtins.elem "http://${homelabFqdn}:${toString cache.port}" config.nix.settings.substituters;
        trustsCache = builtins.elem cache.publicKey config.nix.settings.trusted-public-keys;
        builders = map (machine: machine.hostName) config.nix.buildMachines;
        builderAddress = lib.hasInfix "Host homelab-builder\n  HostName ${homelabFqdn}\n  Port ${toString builder.port}\n" config.programs.ssh.extraConfig;
        builderKnownHost = config.programs.ssh.knownHosts.homelab-builder.hostNames;
      };
      expected = {
        fqdn = homelabFqdn;
        substituter = true;
        trustsCache = true;
        builders = [ "homelab-builder" ];
        builderAddress = true;
        builderKnownHost = [ "[${homelabFqdn}]:${toString builder.port}" ];
      };
    };
  };

  hostTests = {
    homelab = config: {
      testServesTheCacheInsteadOfUsingIt = {
        expr = {
          harmonia = config.services.harmonia.cache.enable;
          bind = config.services.harmonia.cache.settings.bind;
          substitutesFromItself = builtins.any (lib.hasInfix homelabFqdn) config.nix.settings.substituters;
          distributedBuilds = config.nix.distributedBuilds;
        };
        expected = {
          harmonia = true;
          bind = "[::]:${toString cache.port}";
          substitutesFromItself = false;
          distributedBuilds = false;
        };
      };

      # Health check `ssh`: sshd answers, on the builder's port too.
      testRunsSshForTheProbeAndTheBuilder = {
        expr = {
          openssh = config.services.openssh.enable;
          builderPort = builtins.elem builder.port config.services.openssh.ports;
        };
        expected = {
          openssh = true;
          builderPort = true;
        };
      };

      # Health check `tailscale`: the node the fleet reaches it through.
      testJoinsTheTailnet = {
        expr = {
          tailscale = config.services.tailscale.enable;
          fqdn = config.dotfiles.fleet.fqdn;
        };
        expected = {
          tailscale = true;
          fqdn = homelabFqdn;
        };
      };

      # Private Tailscale-only Git HTTP remote for ~/Research/kb.
      testPublishesKbGitOnTailnetOnly = {
        expr = {
          enabled = config.services.kb-git.enable;
          claim = config.dotfiles.tailscale.https.kb-git;
          serve = lib.hasSuffix "/bin/tailscale serve --https=7445 http://127.0.0.1:${toString config.services.kb-git.port}" config.systemd.services.kb-git-serve.serviceConfig.ExecStart;
        };
        expected = {
          enabled = true;
          claim = {
            port = 7445;
            funnel = false;
          };
          serve = true;
        };
      };
    };

    asus = config: {
      # Health check `niri-config`: the probe validates /etc/niri/config.kdl.
      testShipsTheNiriConfigTheProbeValidates = {
        expr = {
          niri = config.programs.niri.enable;
          etc = config.environment.etc ? "niri/config.kdl";
        };
        expected = {
          niri = true;
          etc = true;
        };
      };

      # Home Manager runs standalone (homeConfigurations."schlich@asus"), so
      # the system neither embeds nor activates it.
      testLeavesHomeManagerOutOfTheSystem = {
        expr = {
          module = config ? home-manager;
          unit = config.systemd.services ? "home-manager-schlich";
        };
        expected = {
          module = false;
          unit = false;
        };
      };
    };
  };

  # The T3 Code server's system half: on a stationary host its one owner
  # lingers, so the server runs from boot, and Tailscale Serve publishes the
  # loopback listener on the tailnet alone, never through Funnel.
  t3codeTests = name: config: {
    testT3codeServerIsPublishedToTheTailnetOnly = {
      expr = {
        owner = config.dotfiles.t3code.user;
        linger = config.users.users.${config.dotfiles.t3code.user}.linger;
        claim = config.dotfiles.tailscale.https.t3code;
        serve = lib.hasSuffix "/bin/tailscale serve --https=3773 http://127.0.0.1:3773" config.systemd.services.t3code-tailscale-serve.serviceConfig.ExecStart;
      };
      expected = {
        owner = lib.head (builtins.attrNames (homesOf name));
        linger = if hosts.${name}.hardware.portable then null else true;
        claim = {
          port = 3773;
          funnel = false;
        };
        serve = true;
      };
    };
  };

  # Luvus Web's system half, as for the T3 Code server: the owner lingers on
  # a stationary host and Serve publishes the bridge on the tailnet alone.
  luvusWebTests = name: config: {
    testLuvusWebIsPublishedToTheTailnetOnly = {
      expr = {
        owner = config.dotfiles.luvusWeb.user;
        linger = config.users.users.${config.dotfiles.luvusWeb.user}.linger;
        claim = config.dotfiles.tailscale.https.luvus-web;
        serve = lib.hasSuffix "/bin/tailscale serve --https=4174 http://127.0.0.1:4174" config.systemd.services.luvus-web-tailscale-serve.serviceConfig.ExecStart;
      };
      expected = {
        owner = lib.head (builtins.attrNames (homesOf name));
        linger = if hosts.${name}.hardware.portable then null else true;
        claim = {
          port = 4174;
          funnel = false;
        };
        serve = true;
      };
    };
  };

  # A unit that runs `tailscale serve` or `tailscale funnel` when the system
  # starts it fails a switch that restarts tailscaled before the daemon is
  # back, even though Restart= recovers it seconds later: asus reverted the
  # 2026-11-03 nixpkgs update over t3code-tailscale-serve. Every such unit
  # waits for the backend first (waitForBackend, modules/nixos/fleet/tailscale-https.nix).
  tailscaleServeTests = config: {
    testTailscaleServeUnitsWaitForTheBackend = {
      expr = builtins.attrNames (
        lib.filterAttrs (
          _: unit:
          let
            start = toString (lib.toList (unit.serviceConfig.ExecStart or ""));
            pre = map toString (lib.toList (unit.serviceConfig.ExecStartPre or [ ]));
          in
          unit.enable
          && unit.wantedBy != [ ]
          && (lib.hasInfix "/bin/tailscale serve " start || lib.hasInfix "/bin/tailscale funnel " start)
          && !(lib.elem (toString (config.dotfiles.tailscale.waitForBackend or "")) pre)
        ) config.systemd.services
      );
      expected = [ ];
    };
  };

  # A standalone home follows the host it is named for: the desktop home only
  # on a workstation, ci's traces only where the viewer runs, and the T3 Code
  # server, on loopback, only where the inventory runs it. Den keys a home's
  # scope by its name, so homes of one user that shared a name would all
  # resolve as one host's (den/inventory.nix names them USER@HOST).
  homeTests =
    host: userName: config:
    {
      "testHome_${userName}_FollowsItsHost" = {
        expr = {
          desktop = config.programs.ghostty.enable;
          traces = (config.dotfiles.ci.tracesEndpoint or null) != null;
          t3code = config.dotfiles.t3code.server.enable or false;
          t3codeLoopback =
            !(config.dotfiles.t3code.server.enable or false)
            || lib.hasInfix "-t3code-serve --host 127.0.0.1 --port 3773 " (
              toString config.systemd.user.services.t3code-server.Service.ExecStart
            );
        };
        expected = {
          desktop = host.profile.role == "workstation";
          traces = host.services.nixObservability;
          t3code = host.services.t3code;
          t3codeLoopback = true;
        };
      };
      # The bridge runs where the inventory says, answers to the host's
      # tailnet name, and keeps its pairing link out of the journal.
      "testHome_${userName}_LuvusWebFollowsItsHost" = {
        expr = {
          web = config.dotfiles.luvus.web.enable;
          unit = config.systemd.user.services ? luvus-web;
        }
        // lib.optionalAttrs config.dotfiles.luvus.web.enable (
          let
            unit = config.systemd.user.services.luvus-web;
          in
          {
            publicUrl = config.dotfiles.luvus.web.publicUrl;
            output = unit.Service.StandardOutput;
            after = unit.Unit.After;
          }
        );
        expected = {
          web = host.services.luvusWeb;
          unit = host.services.luvusWeb;
        }
        // lib.optionalAttrs host.services.luvusWeb {
          publicUrl = "https://${host.name}.${host.network.tailnet}:4174";
          output = "truncate:%t/luvus-web.pairing";
          after = [ "luvus.service" ];
        };
      };
    }
    # The server unit keeps retrying while another server holds ~/.t3 and
    # announces the outage (homelab sat `failed` from 2026-11-21 on exit 78).
    // lib.optionalAttrs (config.dotfiles.t3code.server.enable or false) {
      "testHome_${userName}_T3codeServerRecovers" = {
        expr =
          let
            unit = config.systemd.user.services.t3code-server;
          in
          {
            preventExitStatus = unit.Service ? RestartPreventExitStatus;
            startLimit = unit.Unit.StartLimitIntervalSec or null;
            onFailure = unit.Unit.OnFailure or null;
            outageUnit = config.systemd.user.services ? t3code-server-outage;
          };
        expected = {
          preventExitStatus = false;
          startLimit = 0;
          onFailure = [ "t3code-server-outage.service" ];
          outageUnit = true;
        };
      };
    };

  homesOf = name: lib.filterAttrs (_: user: user.home) hosts.${name}.users;

  # Decided from the inventory alone, so dropping a host's empty group never
  # evaluates its system.
  perHost =
    lib.mapAttrs
      (
        name: host:
        let
          inherit (nixosConfigurations.${name}) config;
        in
        lib.optionalAttrs host.deploy.enable (deployTests name config)
        // lib.optionalAttrs (host.profile.remote && name != "homelab") (remoteClientTests config)
        // lib.optionalAttrs host.services.t3code (t3codeTests name config)
        // lib.optionalAttrs host.services.luvusWeb (luvusWebTests name config)
        // lib.optionalAttrs config.services.tailscale.enable (tailscaleServeTests config)
        // (hostTests.${name} or (_: { })) config
        // lib.concatMapAttrs (
          userName: _: homeTests host userName homeConfigurations."${userName}@${name}".config
        ) (homesOf name)
      )
      (
        lib.filterAttrs (
          name: host: host.deploy.enable || host.profile.remote || hostTests ? ${name} || homesOf name != { }
        ) hosts
      );
in
perHost
// {
  # Facts of the evaluated inventory, with the schema's defaults filled in.
  fleet = {
    # Clan deploys every other target over ssh; asus applies itself.
    testOnlyAsusDeploysInPlace = {
      expr = builtins.attrNames (
        lib.filterAttrs (_: host: host.deploy.enable && host.deploy.targetHost == null) hosts
      );
      expected = [ "asus" ];
    };
  };
}
