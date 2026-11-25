# Self-hosted Executor tool and MCP gateway (UsefulSoftwareCo/executor), run as
# a single Podman container on loopback and published privately on the tailnet
# through Tailscale Serve.
#
# When secrets/executor/env.age exists, agenix decrypts it and passes it via
# environmentFiles (BETTER_AUTH_SECRET, EXECUTOR_ENCRYPTION_KEY, etc.). While
# absent, Executor generates and persists auth-secret.key and encryption.key in
# /var/lib/executor (/app/data) on first boot.
{
  config,
  lib,
  ...
}:

let
  port = 4400;
  servePort = config.dotfiles.tailscale.https.executor.port;
  fqdn = config.dotfiles.fleet.fqdn;
  publicUrl = "https://${fqdn}:${toString servePort}";
  # Serializes serve-config updates with the other serve units
  # (modules/nixos/fleet/tailscale-https.nix).
  tailscaleServe = config.dotfiles.tailscale.serve;

  # Pinned immutable release image matching upstream compose.release.yaml.
  image = "ghcr.io/usefulsoftwareco/executor-selfhost:2.0.0-beta.73@sha256:f0669e258ab5af263c1622be21320f0f4bca823b7d59cbd03e0d150c59e05c57";
  dataDir = "/var/lib/executor";

  secretFile = ../../../../secrets/executor/env.age;
  secretReady = builtins.pathExists secretFile;
in
{
  imports = [ ../../fleet/tailscale-https.nix ];

  assertions = [
    {
      assertion = config.services.tailscale.enable;
      message = "Executor publishes through Tailscale Serve; enable services.tailscale.";
    }
  ];

  # Serve, not Funnel: only tailnet devices reach Executor.
  dotfiles.tailscale.https.executor.port = lib.mkDefault port;

  virtualisation.podman.enable = true;
  virtualisation.oci-containers = {
    backend = lib.mkDefault "podman";
    containers.executor = {
      inherit image;
      # Keep the HTTP listener on loopback; Tailscale Serve terminates HTTPS.
      ports = [ "127.0.0.1:${toString port}:4400" ];
      # Persistent PGlite database, apps, builds, and generated keys.
      # /app/motel-data stays ephemeral inside the container per upstream docs.
      volumes = [ "${dataDir}:/app/data" ];
      extraOptions = [ "--init" ];
      environment = {
        # Must match the exact scheme, host, and port clients open.
        BETTER_AUTH_URL = publicUrl;
        EXECUTOR_ENVIRONMENT = "self-host";
      };
      environmentFiles = lib.optional secretReady config.age.secrets.executor-env.path;
    };
  };

  # Ensure the host data directory exists as a real directory (entrypoint.sh
  # refuses symlinks, chowns /app/data to executor:executor, and drops to gosu).
  systemd.tmpfiles.rules = [
    "d ${dataDir} 0700 root root -"
  ];

  # Upstream docs recommend always restarting rather than on-failure because
  # the runtime can exit cleanly on internal signals. oci-containers already
  # sets TimeoutStartSec = 0 for image pulls and TimeoutStopSec = 120.
  systemd.services.podman-executor.serviceConfig = {
    Restart = lib.mkForce "always";
    RestartSec = "10s";
  };

  systemd.services.executor-serve = {
    description = "Publish Executor privately on the tailnet";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "podman-executor.service"
      "tailscaled.service"
    ];
    after = [
      "podman-executor.service"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStartPre = config.dotfiles.tailscale.waitForBackend;
      TimeoutStartSec = "2min";
      ExecStart = "${tailscaleServe} serve --https=${toString servePort} http://127.0.0.1:${toString port}";
      ExecStop = "${tailscaleServe} serve --https=${toString servePort} off";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };
}
// lib.optionalAttrs secretReady {
  age.secrets.executor-env.file = secretFile;
}
