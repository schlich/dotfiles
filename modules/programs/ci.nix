# The ci package that the shell and the ci MCP server both run. On a host
# with a local OpenTelemetry viewer, its NixOS module sets tracesEndpoint, and
# ci sends each dispatch and landing there as a trace when the run ends.
# The variable rides on the package, so only ci exports traces, not every
# program that reads OTEL_EXPORTER_OTLP_*.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.ci;
  ci = inputs.ci.packages.${pkgs.stdenv.hostPlatform.system}.ci;
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
in
{
  # ci's daily `ci prune --apply` backstop for topics landed without
  # `ci park`. It lived in vcs.nix until ci moved to its own repository and
  # was lost then; landed branches piled up again until 2026-10-19.
  imports = [ inputs.ci.homeModules.default ];

  config.services.ci-prune = {
    enable = true;
    package = cfg.package;
    jujutsu = config.programs.jujutsu.package;
    repositories = [ "${config.home.homeDirectory}/dotfiles" ];
    sshAuthSock = "%t/gcr/ssh";
  };

  options.dotfiles.ci = {
    tracesEndpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "http://127.0.0.1:4318/v1/traces";
      description = "OTLP/HTTP traces URL that ci exports each dispatch and landing to.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The ci package, carrying tracesEndpoint when it is set.";
    };
  };

  config.dotfiles.ci.package =
    if cfg.tracesEndpoint == null then
      ci
    else
      wrapWithConfig {
        package = ci;
        env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = cfg.tracesEndpoint;
      };
}
