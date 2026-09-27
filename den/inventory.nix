{
  inputs,
  lib,
  ...
}:
let
  inventory = {
    asus = {
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
        gpu = "amd";
        portable = true;
        development = true;
        xr = true;
        secrets = false;
        remote = true;
      };
      policy = {
        criticality = "workstation";
        autoDeploy = false;
        requireReview = true;
        rollback = true;
        healthChecks = [
          "niri-config"
          "home-manager-nixos"
        ];
      };
    };

    asus-headless = {
      users.schlich = { };
      profile = {
        role = "server";
        desktop = "none";
        gpu = "amd";
        portable = true;
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

    asus-usb = {
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
        gpu = "amd";
        portable = true;
        development = true;
        xr = true;
        secrets = false;
        remote = true;
      };
      policy = {
        criticality = "disposable";
        autoDeploy = false;
        requireReview = true;
        rollback = true;
        healthChecks = [
          "niri-config"
          "home-manager-nixos"
        ];
      };
    };

    homelab = {
      users.schlich = { };
      profile = {
        role = "server";
        # A local session for debugging on the machine itself.
        desktop = "niri";
        gpu = "intel";
        portable = false;
        development = false;
        xr = false;
        secrets = false;
        remote = true;
      };
      policy = {
        criticality = "critical";
        autoDeploy = false;
        requireReview = true;
        rollback = true;
        healthChecks = [
          "ssh"
          "tailscale"
        ];
      };
    };
  };

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
