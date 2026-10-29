{
  config,
  den,
  lib,
  ...
}:
let
  # Canaries deploy main themselves and keep their revert reports;
  # workstations fetch the reports over ssh to announce them.
  canaries = lib.filterAttrs (
    _: host: host.policy.autoDeploy && host.deploy.targetHost != null
  ) den.hosts.x86_64-linux;
in
{
  # The inventory's deployment policy, handed to modules/nixos/system-switch.nix.
  den.aspects.deploy-policy = {
    meta = config.myConfig.aspectPolicy.deployment;
    includes = [
      (
        { host, ... }:
        {
          nixos.dotfiles.deploy = {
            inherit (host.policy) autoDeploy healthChecks;
            notify = lib.mkIf (host.profile.role == "workstation" && host.profile.desktop != "none") {
              enable = true;
              sources = lib.mapAttrsToList (
                _: canary:
                if canary.deploy.sshPort == null then
                  canary.deploy.targetHost
                else
                  "ssh://${canary.deploy.targetHost}:${toString canary.deploy.sshPort}"
              ) (removeAttrs canaries [ host.name ]);
            };
          };
        }
      )
    ];
  };
}
