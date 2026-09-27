{ lib }:
let
  gpuAspects = {
    amd = "gpu-amd";
  };

  behaviorAspects =
    profile:
    # The workstation aspect already includes base; servers select it here.
    (
      if profile.role == "workstation" then
        [ "workstation" ]
      else if profile.role == "wsl" then
        [ "wsl" ]
      else
        [
          "base"
          "server"
        ]
    )
    ++ lib.optional (profile.desktop == "niri") "desktop-niri"
    ++ lib.optional (profile.desktop == "none") "headless"
    ++ lib.optional profile.portable "laptop"
    ++ lib.optional profile.development "development"
    ++ lib.optional profile.remote "remote"
    ++ lib.optional profile.secrets "secrets"
    ++ lib.optional profile.xr "xr"
    ++ lib.optional (builtins.hasAttr profile.gpu gpuAspects) gpuAspects.${profile.gpu};

  hostErrors =
    {
      name,
      profile,
      policy,
      hasSecretsMechanism,
    }:
    lib.optionals (profile.desktop == "niri" && profile.role != "workstation") [
      "host ${name}: desktop=niri requires role=workstation"
    ]
    ++ lib.optionals (profile.xr && !(profile.role == "workstation" && profile.desktop == "niri")) [
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
