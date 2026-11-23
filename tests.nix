{ lib, ... }:
let
  profileTools = import ./den/model/profile.nix { inherit lib; };
  policy = {
    criticality = "workstation";
    autoDeploy = false;
    requireReview = true;
    rollback = true;
    healthChecks = [ ];
  };
  # The inventory's homes read the evaluated systems from `config`; these
  # tests read only its hosts, so the homes are never evaluated.
  inventory = import ./den/inventory.nix {
    inherit lib;
    inputs = { };
    config = { };
  };
  hosts = inventory.den.hosts.x86_64-linux;
in
{
  testWorkstationProfileResolvesToBehaviorAspects = {
    expr = profileTools.behaviorAspects {
      profile = {
        role = "workstation";
        desktop = "niri";
        development = true;
        xr = true;
        secrets = false;
        remote = true;
      };
      hardware = {
        gpu = "amd";
        portable = true;
      };
    };
    expected = [
      "workstation"
      "desktop-niri"
      "laptop"
      "development"
      "remote"
      "xr"
      "gpu-amd"
    ];
  };

  testHeadlessProfileResolvesWithoutDesktopAspects = {
    expr = profileTools.behaviorAspects {
      profile = {
        role = "server";
        desktop = "none";
        development = false;
        xr = false;
        secrets = false;
        remote = true;
      };
      hardware = {
        gpu = "intel";
        portable = false;
      };
    };
    expected = [
      "base"
      "server"
      "headless"
      "remote"
    ];
  };

  testServicesFollowTheFirstBehaviorAspect = {
    expr = profileTools.hostAspects {
      profile = {
        role = "server";
        desktop = "none";
        development = false;
        xr = false;
        secrets = false;
        remote = true;
      };
      hardware = {
        gpu = "none";
        portable = false;
      };
      services = {
        jjCiWebhook = false;
        nixObservability = false;
        paseo = true;
        opencodeServer = false;
        t3code = true;
        luvusWeb = true;
        rex = true;
        crossStream = true;
      };
    };
    expected = [
      "base"
      "paseo"
      "t3code"
      "luvus-web"
      "rex"
      "cross-stream"
      "server"
      "headless"
      "remote"
    ];
  };

  testInventoryServicesSelectTheirAspects = {
    expr = lib.mapAttrs (_: host: profileTools.selectedServices host.services) hosts;
    expected = {
      asus = [
        "jj-ci-webhook"
        "nix-observability"
        "t3code"
      ];
      asus-headless = [ ];
      asus-usb = [ ];
      homelab = [
        "paseo"
        "opencode-server"
        "t3code"
        "luvus-web"
        "rex"
        "cross-stream"
      ];
    };
  };

  testServerMaySelectAGraphicalDesktop = {
    expr = profileTools.hostErrors {
      name = "desktop-server";
      profile = {
        role = "server";
        desktop = "niri";
        development = false;
        xr = false;
        secrets = false;
        remote = false;
      };
      inherit policy;
      hasSecretsMechanism = true;
    };
    expected = [ ];
  };

  testXRRequiresAGraphicalWorkstation = {
    expr = profileTools.hostErrors {
      name = "invalid-xr";
      profile = {
        role = "workstation";
        desktop = "none";
        development = false;
        xr = true;
        secrets = false;
        remote = false;
      };
      inherit policy;
      hasSecretsMechanism = true;
    };
    expected = [ "host invalid-xr: xr=true requires a graphical workstation" ];
  };

  testSecretsRequireARepositoryMechanism = {
    expr = profileTools.hostErrors {
      name = "invalid-secrets";
      profile = {
        role = "server";
        desktop = "none";
        development = false;
        xr = false;
        secrets = true;
        remote = false;
      };
      inherit policy;
      hasSecretsMechanism = false;
    };
    expected = [ "host invalid-secrets: secrets=true requires secrets/secrets.nix" ];
  };

  testCriticalAutoDeployRequiresSafeguards = {
    expr = profileTools.hostErrors {
      name = "unsafe-policy";
      profile = {
        role = "server";
        desktop = "none";
        development = false;
        xr = false;
        secrets = false;
        remote = false;
      };
      policy = {
        criticality = "critical";
        autoDeploy = true;
        requireReview = false;
        rollback = false;
        healthChecks = [ ];
      };
      hasSecretsMechanism = true;
    };
    expected = [
      "host unsafe-policy: critical autoDeploy requires review, rollback, and health checks"
    ];
  };

  testEveryDeclaredHostHasValidProfileAndPolicy = {
    expr = builtins.deepSeq hosts true;
    expected = true;
  };

  testInventoryPolicyGuardScalesWithDeclaredHosts = {
    expr = builtins.all (
      host:
      host.policy.requireReview
      && host.policy.rollback
      && (!host.policy.autoDeploy || host.policy.healthChecks != [ ])
    ) (builtins.attrValues hosts);
    expected = true;
  };

  # Workstations fetch a canary's revert reports over ssh, so a canary needs
  # a destination to fetch them from.
  testCanariesHaveADeployTarget = {
    expr = builtins.attrNames (
      lib.filterAttrs (_: host: host.policy.autoDeploy && (host.deploy.targetHost or null) == null) hosts
    );
    expected = [ ];
  };
}
