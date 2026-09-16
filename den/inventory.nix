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
        platform = "asus";
        storage = "internal";
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
        platform = "asus";
        storage = "internal";
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
        platform = "asus";
        storage = "usb";
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
        platform = "homelab";
        storage = "internal";
        desktop = "none";
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

  validateHost =
    name: host:
    let
      inherit (host) profile policy;
      graphical = profile.desktop != "none";
      hasSecretsMechanism = builtins.pathExists ../secrets/secrets.nix;
    in
    if profile.role == "server" && profile.desktop == "niri" then
      throw "host ${name}: server hosts cannot select desktop=niri"
    else if profile.xr && !(profile.role == "workstation" && profile.desktop == "niri") then
      throw "host ${name}: xr=true requires a graphical workstation"
    else if profile.desktop == "niri" && !graphical then
      throw "host ${name}: desktop=niri must select graphical infrastructure"
    else if profile.secrets && !hasSecretsMechanism then
      throw "host ${name}: secrets=true requires secrets/secrets.nix"
    else if
      policy.autoDeploy
      && policy.criticality == "critical"
      && (!policy.requireReview || !policy.rollback || policy.healthChecks == [ ])
    then
      throw "host ${name}: critical autoDeploy requires review, rollback, and health checks"
    else
      true;

  withInstantiate = lib.mapAttrs (
    _: host:
    host
    // {
      instantiate = args: inputs.nixpkgs.lib.nixosSystem (args // { specialArgs = { inherit inputs; }; });
    }
  ) inventory;
  validated = builtins.seq (lib.mapAttrsToList validateHost inventory) withInstantiate;
in
{
  den.hosts.x86_64-linux = validated;
}
