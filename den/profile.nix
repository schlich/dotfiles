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

  behaviorAspects =
    profile:
    roleAspects.${profile.role}
    ++ desktopAspects.${profile.desktop}
    ++ lib.concatMap ({ flag, aspect }: lib.optional profile.${flag} aspect) flagAspects
    ++ gpuAspects.${profile.gpu} or [ ];

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
  inherit behaviorAspects hostErrors validateHost;
}
