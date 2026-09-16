{ source }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.paseo-selfhosted;
in
{
  options.services.paseo-selfhosted = {
    enable = lib.mkEnableOption "the self-hosted Paseo web UI";

    daemonHost = lib.mkOption {
      type = lib.types.str;
      default = "host.docker.internal:6767";
      description = "Host and port of the running Paseo daemon.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Host port on which to expose the Paseo web UI.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "paseo-selfhosted:latest";
      description = "Docker image name used for the self-hosted web UI.";
    };

    source = lib.mkOption {
      type = lib.types.path;
      default = source;
      description = "Source tree containing the Paseo self-hosted Dockerfile.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.docker.enable = true;

    systemd.services.paseo-selfhosted = {
      description = "Paseo self-hosted web UI";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        ${pkgs.docker}/bin/docker build \
          --tag ${lib.escapeShellArg cfg.image} \
          ${lib.escapeShellArg cfg.source}
      '';

      script = ''
        exec ${pkgs.docker}/bin/docker run --rm --name paseo-selfhosted \
          --publish ${toString cfg.port}:80 \
          --env PASEO_DAEMON_HOST=${lib.escapeShellArg cfg.daemonHost} \
          --add-host host.docker.internal:host-gateway \
          ${lib.escapeShellArg cfg.image}
      '';

      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";
        TimeoutStartSec = 0;
        ExecStopPost = "-${pkgs.docker}/bin/docker rm --force paseo-selfhosted";
      };
    };
  };
}
