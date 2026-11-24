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
  # The ssh destination a host is reached at: its deploy target, on the
  # port for unattended logins when it names one, or else its own name,
  # which the tailnet resolves.
  destination =
    name: host:
    if host.deploy.targetHost == null then
      name
    else if host.deploy.sshPort == null then
      host.deploy.targetHost
    else
      "ssh://${host.deploy.targetHost}:${toString host.deploy.sshPort}";
in
{
  # The inventory's deployment policy, handed to modules/nixos/fleet/system-switch.nix.
  den.aspects.deploy-policy = {
    meta = config.myConfig.aspectPolicy.deployment;
    includes = [
      (
        { host, ... }:
        {
          nixos.dotfiles.deploy = {
            inherit (host.policy) autoDeploy healthChecks;
            fleet = lib.mapAttrs destination den.hosts.x86_64-linux;
            notify = lib.mkIf (host.profile.role == "workstation" && host.profile.desktop != "none") {
              enable = true;
              sources = lib.attrValues (lib.mapAttrs destination (removeAttrs canaries [ host.name ]));
            };
          };
        }
      )
    ];
  };
}
