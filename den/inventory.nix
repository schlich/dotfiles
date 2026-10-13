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
    policy.healthChecks = [
      "niri-config"
      "home-manager-nixos"
    ];
  };

  hostLayers = {
    asus = [
      asusHardware
      personalWorkstation
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
        policy = {
          criticality = "critical";
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
      instantiate = args: inputs.nixpkgs.lib.nixosSystem (args // { specialArgs = { inherit inputs; }; });
    }
  ) inventory;
  validated = builtins.deepSeq (lib.mapAttrsToList profileTools.validateHost inventory) withInstantiate;
in
{
  den.hosts.x86_64-linux = validated;
}
