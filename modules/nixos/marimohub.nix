# marimohub: the long-lived runtime for executable knowledge documents.
#
# The hub is configured only through MARIMOHUB_* variables. This module
# selects the documented single-host shape: `fs` storage on local disk and
# rootless `podman` compute, with one container per kernel built from a Nix
# sandbox image. The repository stays the source of truth: notebooks reach
# the hub as read-only push-sync versions (`workbench sync`), and the hub's
# own version history is operational state under `stateDir`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.services.marimohub;

  # Rootless Podman needs a user manager (lingering) for its cgroup and
  # session bus, so the account has a fixed UID for /run/user/UID.
  runtimeDir = "/run/user/${toString cfg.uid}";

  imageRef = image: "${image.imageName}:${image.imageTag}";

  loadImages = pkgs.writeShellApplication {
    name = "marimohub-load-images";
    runtimeInputs = [ config.virtualisation.podman.package ];
    text = lib.concatMapStrings (image: ''
      if ! podman image exists ${lib.escapeShellArg (imageRef image)}; then
        ${image} | podman load
      fi
    '') cfg.compute.images;
  };

  environment = {
    PORT = toString cfg.port;
    MARIMOHUB_BIND_HOST = cfg.bindHost;
    MARIMOHUB_SEA_CACHE_DIR = "${cfg.stateDir}/sea-cache";
    MARIMOHUB_RUN_MAINTENANCE = "true";

    MARIMOHUB_STORAGE_BACKEND = "fs";
    MARIMOHUB_STORAGE_FS_ROOT = "${cfg.stateDir}/storage";

    MARIMOHUB_COMPUTE_BACKEND = cfg.compute.backend;
    MARIMOHUB_SANDBOX_EXPOSURE = cfg.sandboxExposure;
    MARIMOHUB_PERSIST_WORKSPACE = "source";

    MARIMOHUB_AUTH_BACKEND = cfg.auth.backend;
    MARIMOHUB_JOBS = if cfg.jobs.enable then "on" else "off";
  }
  // lib.optionalAttrs (cfg.compute.backend == "podman") {
    MARIMOHUB_COMPUTE_IMAGE = lib.concatMapStringsSep "," imageRef cfg.compute.images;
    # Kernel ports stay on loopback; browsers reach them through the hub.
    MARIMOHUB_COMPUTE_PODMAN_HOST = "localhost";
    MARIMOHUB_COMPUTE_PODMAN_BIND_HOST = "127.0.0.1";
    XDG_RUNTIME_DIR = runtimeDir;
    DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtimeDir}/bus";
  }
  // lib.optionalAttrs (cfg.auth.backend == "proxy-header") {
    MARIMOHUB_AUTH_PROXY_HEADER = cfg.auth.proxyHeader;
    MARIMOHUB_AUTH_ALLOWED_EMAIL_DOMAINS = lib.concatStringsSep "," cfg.auth.allowedEmailDomains;
  }
  // lib.optionalAttrs (cfg.superAdmins != [ ]) {
    MARIMOHUB_SUPER_ADMINS = lib.concatStringsSep "," cfg.superAdmins;
  }
  // lib.optionalAttrs (cfg.publicUrl != null) {
    MARIMOHUB_APP_BASE_URL = cfg.publicUrl;
  }
  // cfg.settings;
in
{
  options.services.marimohub = {
    enable = mkEnableOption "the marimohub notebook server";

    package = mkOption {
      type = types.package;
      description = "The marimohub server package.";
    };

    user = mkOption {
      type = types.str;
      default = "marimohub";
      description = "Account that runs the hub and owns its rootless Podman storage.";
    };

    uid = mkOption {
      type = types.int;
      default = 2718;
      description = "Fixed UID of the hub account, used for its /run/user directory.";
    };

    stateDir = mkOption {
      type = types.path;
      default = "/var/lib/marimohub";
      description = ''
        Home of the hub account. Holds the `fs` object store (`storage/`), the
        server's unpacked bundle (`sea-cache/`), and Podman's image store.
        Back up `storage/`; it is the hub's only database.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 3000;
      description = "HTTP port of the hub.";
    };

    bindHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Listen address. Keep loopback behind a reverse proxy or Tailscale Serve.";
    };

    publicUrl = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "https://homelab.example.ts.net";
      description = "Public URL for browser links (MARIMOHUB_APP_BASE_URL).";
    };

    sandboxExposure = mkOption {
      type = types.enum [
        "proxy"
        "subdomain"
      ];
      default = "proxy";
      description = ''
        How kernels reach the browser. `proxy` forwards kernel traffic
        through the hub's authentication, which upstream recommends when
        kernel ports stay on loopback and browsers are on other machines.
      '';
    };

    compute = {
      backend = mkOption {
        type = types.enum [
          "podman"
          "none"
        ];
        default = "podman";
        description = ''
          `podman` runs each kernel in a rootless container. `none` browses
          notebooks without kernels. Upstream's `local` backend runs kernels
          as unisolated host processes and is development-only, so it is not
          offered here.
        '';
      };

      images = mkOption {
        type = types.listOf types.package;
        default = [ ];
        description = ''
          Sandbox images as `dockerTools.streamLayeredImage` scripts. They are
          loaded into the hub account's Podman store before the hub starts;
          the first is the default, and notebooks may select the others.
        '';
      };
    };

    auth = {
      backend = mkOption {
        type = types.enum [
          "proxy-header"
          "oidc"
          "dev"
        ];
        default = "proxy-header";
        description = ''
          `proxy-header` trusts an identity header from a proxy on this host,
          such as Tailscale Serve. `dev` signs everyone in as an administrator
          and is only for a hub bound to loopback on a single-user machine.
        '';
      };

      proxyHeader = mkOption {
        type = types.str;
        default = "Tailscale-User-Login";
        description = "Identity header set by the trusted proxy.";
      };

      allowedEmailDomains = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "gmail.com" ];
        description = "Login domains admitted in proxy-header mode (required by upstream).";
      };
    };

    superAdmins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Emails or user IDs with implicit admin on every project.";
    };

    jobs.enable = mkEnableOption "scheduled and on-demand notebook jobs";

    settings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        MARIMOHUB_SESSION_IDLE_TIMEOUT_SECONDS = "900";
      };
      description = "Further MARIMOHUB_* variables, overriding the module's own.";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        A file outside the Nix store with secret variables such as
        MARIMOHUB_SECRETS_KEK or OIDC client secrets.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.compute.backend != "podman" || cfg.compute.images != [ ];
        message = "services.marimohub.compute.images must name at least one sandbox image for podman compute.";
      }
      {
        assertion = cfg.auth.backend != "proxy-header" || cfg.auth.allowedEmailDomains != [ ];
        message = "services.marimohub.auth.allowedEmailDomains is required in proxy-header mode.";
      }
      {
        assertion = cfg.auth.backend != "dev" || cfg.bindHost == "127.0.0.1";
        message = "services.marimohub dev auth signs everyone in as an administrator; bind it to 127.0.0.1.";
      }
    ];

    virtualisation.podman.enable = mkIf (cfg.compute.backend == "podman") true;

    users.groups.${cfg.user} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      inherit (cfg) uid;
      group = cfg.user;
      home = cfg.stateDir;
      createHome = true;
      # Rootless Podman maps container users into this subordinate range.
      autoSubUidGidRange = true;
      linger = true;
    };

    systemd.services.marimohub = {
      description = "marimohub notebook server";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "user@${toString cfg.uid}.service"
      ];
      wants = [ "network-online.target" ];
      requires = lib.optional (cfg.compute.backend == "podman") "user@${toString cfg.uid}.service";
      inherit environment;
      # The Podman backend shells out to `podman`; rootless Podman needs the
      # setuid newuidmap/newgidmap wrappers.
      path = lib.optionals (cfg.compute.backend == "podman") [
        config.virtualisation.podman.package
        "/run/wrappers"
      ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = cfg.stateDir;
        ExecStartPre = lib.optional (cfg.compute.backend == "podman") (lib.getExe loadImages);
        ExecStart = lib.getExe cfg.package;
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = "5s";
        # Image loads can take minutes on the first start after a change.
        TimeoutStartSec = "15min";
        StateDirectory = lib.mkIf (cfg.stateDir == "/var/lib/marimohub") "marimohub";
        StateDirectoryMode = "0700";
        # Not NoNewPrivileges: rootless Podman needs setuid newuidmap.
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "full";
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = false;
      };
    };
  };
}
