{ lib }:
let
  # What each profile fact needs. An aspect's own dependencies stay in its
  # `includes`: the workstation aspect already includes base.
  roleAspects = {
    workstation = [ "workstation" ];
    wsl = [ "wsl" ];
    server = [
      "base"
      "server"
    ];
  };

  desktopAspects = {
    niri = [ "desktop-niri" ];
    none = [ "headless" ];
  };

  # A list, not an attrset, so the aspect order stays as written.
  flagAspects = [
    {
      flag = "portable";
      aspect = "laptop";
    }
    {
      flag = "development";
      aspect = "development";
    }
    {
      flag = "remote";
      aspect = "remote";
    }
    {
      flag = "secrets";
      aspect = "secrets";
    }
    {
      flag = "xr";
      aspect = "xr";
    }
  ];

  gpuAspects = {
    amd = [ "gpu-amd" ];
  };

  # The long-running services a host runs, from its `services` facts. A list
  # for the same reason as flagAspects.
  serviceAspects = [
    {
      service = "jjCiWebhook";
      aspect = "jj-ci-webhook";
    }
    {
      service = "nixObservability";
      aspect = "nix-observability";
    }
    {
      service = "paseo";
      aspect = "paseo";
    }
    {
      service = "opencodeServer";
      aspect = "opencode-server";
    }
    {
      service = "t3code";
      aspect = "t3code";
    }
    {
      service = "crossStream";
      aspect = "cross-stream";
    }
  ];

  behaviorAspects =
    profile:
    roleAspects.${profile.role}
    ++ desktopAspects.${profile.desktop}
    ++ lib.concatMap ({ flag, aspect }: lib.optional profile.${flag} aspect) flagAspects
    ++ gpuAspects.${profile.gpu} or [ ];

  selectedServices =
    services:
    lib.concatMap ({ service, aspect }: lib.optional services.${service} aspect) serviceAspects;

  # Services sit right after the first behavior aspect (base or workstation)
  # so package order, and with it every closure, stays stable.
  hostAspects =
    { profile, services, ... }:
    let
      behavior = behaviorAspects profile;
    in
    [ (builtins.head behavior) ] ++ selectedServices services ++ builtins.tail behavior;

  hostErrors =
    {
      name,
      profile,
      policy,
      hasSecretsMechanism,
    }:
    lib.optionals (profile.xr && !(profile.role == "workstation" && profile.desktop == "niri")) [
      "host ${name}: xr=true requires a graphical workstation"
    ]
    ++ lib.optionals (profile.secrets && !hasSecretsMechanism) [
      "host ${name}: secrets=true requires secrets/secrets.nix"
    ]
    ++ lib.optionals (
      policy.autoDeploy
      && policy.criticality == "critical"
      && (!policy.requireReview || !policy.rollback || policy.healthChecks == [ ])
    ) [ "host ${name}: critical autoDeploy requires review, rollback, and health checks" ];

  validateHost =
    name: host:
    let
      errors = hostErrors {
        inherit name;
        inherit (host) profile policy;
        hasSecretsMechanism = builtins.pathExists ../secrets/secrets.nix;
      };
    in
    if errors == [ ] then true else throw (lib.concatStringsSep "; " errors);
in
{
  inherit
    behaviorAspects
    selectedServices
    hostAspects
    hostErrors
    validateHost
    ;
}
