{
  config,
  inputs,
  lib,
  ...
}:
let
  # Hosts are built from layers, like namespaces in a tree: each host merges
  # the layers it sits under, and a later layer's facts win over an earlier
  # one's. Lists are replaced, not appended.
  fleet = {
    profile = {
      role = "workstation";
      desktop = "none";
      gpu = "none";
      portable = false;
      development = false;
      xr = false;
      secrets = false;
      remote = false;
    };
    services = {
      jjCiWebhook = false;
      nixObservability = false;
      paseo = false;
      opencodeServer = false;
      t3code = false;
      crossStream = false;
    };
    # Clan logs in as the everyday user and escalates with sudo.
    deploy.targetUser = "schlich";
    # Every host joins the same tailnet; den/aspects/fleet-network.nix
    # derives each one's address from it.
    network.tailnet = "tail338351.ts.net";
    policy = {
      criticality = "workstation";
      autoDeploy = false;
      requireReview = true;
      rollback = true;
      healthChecks = [ ];
    };
  };

  asusHardware.profile = {
    gpu = "amd";
    portable = true;
  };

  personalWorkstation = {
    users.schlich = {
      home = true;
      primary = true;
    };
    profile = {
      role = "workstation";
      desktop = "niri";
      development = true;
      xr = true;
      remote = true;
    };
    # tests/den-config.nix tests that each probe has something to watch.
    policy.healthChecks = [ "niri-config" ];
  };

  hostLayers = {
    asus = [
      asusHardware
      personalWorkstation
      {
        services = {
          jjCiWebhook = true;
          nixObservability = true;
          # An execution environment while the laptop is awake; the desktop
          # app is its client (docs/T3-FLEET.md).
          t3code = true;
        };
        # Deployed in place: `clan machines update asus` over ssh to localhost.
        deploy.enable = true;
      }
    ];

    asus-headless = [
      asusHardware
      {
        users.schlich = { };
        profile.role = "server";
      }
    ];

    asus-usb = [
      asusHardware
      personalWorkstation
      { policy.criticality = "disposable"; }
    ];

    homelab = [
      {
        # The shell home only; den/aspects/users/schlich.nix keeps desktop
        # pieces to workstations.
        users.schlich.home = true;
        profile = {
          role = "server";
          # A local session for debugging on the machine itself.
          desktop = "niri";
          gpu = "intel";
          remote = true;
          # nixbot's GitHub App secrets, decrypted with homelab's host key.
          secrets = true;
        };
        services = {
          paseo = true;
          opencodeServer = true;
          # The always-on execution environment of the agent fleet.
          t3code = true;
          crossStream = true;
        };
        deploy = {
          enable = true;
          targetHost = "homelab";
          # Tailscale SSH admits root from the tailnet, so activation needs
          # no sudo; homelab's sudo wants a password over Tailscale SSH.
          targetUser = "root";
          # Port 22 is Tailscale SSH, whose check mode hangs a BatchMode
          # login; key-based automation uses OpenSSH here
          # (docs/homelab-builds.md).
          sshPort = 2222;
        };
        policy = {
          criticality = "critical";
          # The canary: it stages each landing of main on its own, before
          # anyone switches a workstation, and reverts one that breaks these.
          # tests/den-config.nix tests what each one watches.
          autoDeploy = true;
          healthChecks = [
            "ssh"
            "tailscale"
          ];
        };
      }
    ];
  };

  inventory = lib.mapAttrs (_: layers: lib.foldl' lib.recursiveUpdate fleet layers) hostLayers;

  profileTools = import ./profile.nix { inherit lib; };

  withInstantiate = lib.mapAttrs (
    _: host:
    host
    // {
      # Keep the module list Den resolved for the host beside the
      # evaluated configuration, so Clan's machines (flake.nix) are exactly
      # what nixosConfigurations builds.
      instantiate =
        args:
        inputs.nixpkgs.lib.nixosSystem (args // { specialArgs = { inherit inputs; }; })
        // {
          denModules = args.modules;
        };
    }
  ) inventory;
  validated = builtins.deepSeq (lib.mapAttrsToList profileTools.validateHost inventory) withInstantiate;

  # Home Manager runs apart from the system: each user with `home = true`
  # gets homeConfigurations."USER@HOST", the name `nh home switch` looks up
  # for that user on that host. The home takes its host's package set, with
  # the overlays and nixpkgs settings the system has, and sees the system as
  # osConfig.
  homes = lib.concatMapAttrs (
    hostName: host:
    lib.mapAttrs' (
      userName: _:
      let
        system = config.flake.nixosConfigurations.${hostName};
      in
      lib.nameValuePair "${userName}@${hostName}" {
        # Den names a home after its bare user and keys its scope by kind and
        # name, so one user's homes on several hosts would share one scope and
        # all resolve as whichever came first. Name each after its host too,
        # and look the user's aspect up by the user name that no longer
        # matches.
        name = lib.mkOverride 10 "${userName}@${hostName}";
        aspect = config.den.aspects.${userName};
        inherit (system) pkgs;
        instantiate =
          { pkgs, modules }:
          inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs modules;
            extraSpecialArgs = {
              inherit inputs;
              osConfig = system.config;
            };
          };
      }
    ) (lib.filterAttrs (_: user: user.home or false) (host.users or { }))
  ) inventory;
in
{
  den.hosts.x86_64-linux = validated;
  den.homes.x86_64-linux = homes;
}
