# The ci package that the shell and the ci MCP server both run. On a host
# with a local OpenTelemetry viewer, its NixOS module sets tracesEndpoint, and
# ci sends each dispatch and landing there as a trace when the run ends.
# The variable rides on the package, so only ci exports traces, not every
# program that reads OTEL_EXPORTER_OTLP_*.
#
# The workflow itself is opt-in per repository: one opts in when jj's config
# sets `ci.enable = true` there, which `jj config set --repo ci.enable true`
# does for a single clone and `repositories` below does for a path. Agent
# instructions, ci's context-status hooks, and the prompt's ci segment apply
# only there; every other repository uses plain jj.
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
  # Asks the wrapped jj, whose configuration carries the scope below, so a
  # clone's own setting and a listed path opt in alike.
  ciEnabled = pkgs.writeShellApplication {
    name = "ci-enabled";
    text = ''
      # ci-enabled                exit 0 in a repository that opted into ci, 1 elsewhere
      # ci-enabled COMMAND ARGS   run COMMAND there; elsewhere exit 0 without output
      enabled=$(${lib.getExe config.programs.jujutsu.package} --ignore-working-copy config get ci.enable 2>/dev/null || true)
      if [ "$enabled" = true ]; then
        if [ "$#" -gt 0 ]; then exec "$@"; fi
        exit 0
      fi
      if [ "$#" -gt 0 ]; then exit 0; fi
      exit 1
    '';
  };
in
{
  # ci's daily `ci prune --apply` backstop for topics landed without
  # `ci park`. It lived in vcs.nix until ci moved to its own repository and
  # was lost then; landed branches piled up again until 2026-10-19.
  imports = [ inputs.ci.homeModules.default ];

  # Off since 2026-10-20: dotfiles, its only repository, moved to luvus and
  # Git. List another ci repository here and enable it again to bring it back.
  config.services.ci-prune = {
    enable = false;
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
    repositories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "~/Projects/ci" ];
      description = ''
        Repositories that use the ci trunk workflow, as paths jj's
        `--when.repositories` matches (a leading `~` is the home directory).
        Each gets `ci.enable = true` in jj's config for every clone and
        workspace there, as `jj config set --repo ci.enable true` gives one
        clone.
      '';
    };
    enabledCommand = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "`ci-enabled`, which exits 0 only in a repository that opted into ci.";
    };
  };

  # The repositories that used ci when it became opt-in on 2026-10-24.
  config.dotfiles.ci.repositories = [
    "~/Projects/ci"
    "~/Projects/xr-ui"
    "~/newsletter-agent"
    "~/kb"
  ];
  config.programs.jujutsu.settings."--scope" = lib.optional (cfg.repositories != [ ]) {
    "--when".repositories = cfg.repositories;
    ci.enable = true;
  };
  config.dotfiles.ci.enabledCommand = ciEnabled;
  config.home.packages = [ ciEnabled ];

  config.dotfiles.ci.package =
    if cfg.tracesEndpoint == null then
      ci
    else
      wrapWithConfig {
        package = ci;
        env.OTEL_EXPORTER_OTLP_TRACES_ENDPOINT = cfg.tracesEndpoint;
      };
}
