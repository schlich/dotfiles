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

  # A standalone home follows the host it is named for: the desktop home only
  # on a workstation, and ci's traces only where the viewer runs. Den keys a
  # home's scope by its name, so homes of one user that shared a name would
  # all resolve as one host's (den/inventory.nix names them USER@HOST).
  homeTests = host: userName: config: {
    "testHome_${userName}_FollowsItsHost" = {
      expr = {
        desktop = config.programs.ghostty.enable;
        traces = (config.dotfiles.ci.tracesEndpoint or null) != null;
      };
      expected = {
        desktop = host.profile.role == "workstation";
        traces = host.services.nixObservability;
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
