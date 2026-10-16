{
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
      classes = [
        "user"
        "homeManager"
      ];
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
    policy.healthChecks = [
      "niri-config"
      "home-manager-nixos"
    ];
  };

  hostLayers = {
    asus = [
      asusHardware
      personalWorkstation
      {
        services = {
          jjCiWebhook = true;
          nixObservability = true;
        };
        # Deployed in place: `clan machines update asus` over ssh to localhost.
        deploy.enable = true;
        # Switched by hand at its keyboard, so the watch needs only enough
        # samples (3 at 15s) to revert a breach on its own.
        policy.watchDuration = 45;
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
        users.schlich.classes = [
          "user"
          "homeManager"
        ];
        profile = {
          role = "server";
          # A local session for debugging on the machine itself.
          desktop = "niri";
          gpu = "intel";
          remote = true;
        };
        services = {
          paseo = true;
          opencodeServer = true;
          crossStream = true;
        };
        deploy = {
          enable = true;
          targetHost = "homelab";
          # Tailscale SSH admits root from the tailnet, so activation needs
          # no sudo; homelab's sudo wants a password over Tailscale SSH.
          targetUser = "root";
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
in
{
  den.hosts.x86_64-linux = validated;
}
