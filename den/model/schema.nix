{
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

  # What the machine is, apart from what it is used for (the profile).
  hardwareType = types.submodule {
    options = {
      gpu = mkOption {
        type = types.enum [
          "none"
          "amd"
          "intel"
          "nvidia"
          "apple"
        ];
        default = "none";
        description = "The primary graphics hardware family.";
      };
      portable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the host is treated as a portable computer.";
      };
    };
  };

  profileType = types.submodule {
    options = {
      role = mkOption {
        type = types.enum [
          "workstation"
          "server"
          "wsl"
        ];
        default = "workstation";
        description = "The operational role of the host.";
      };
      desktop = mkOption {
        type = types.enum [
          "none"
          "niri"
        ];
        default = "none";
        description = "The graphical session selected for the host.";
      };
      development = mkOption {
        type = types.bool;
        default = false;
        description = "Whether development tooling is expected on the host.";
      };
      xr = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the host is used for XR work.";
      };
      secrets = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the host consumes the repository secrets mechanism.";
      };
      remote = mkOption {
        type = types.bool;
        default = false;
        description = "Whether remote access services are part of the host contract.";
      };
    };
  };

  # One switch per long-running service; den/model/profile.nix maps each to the
  # aspect that runs it.
  servicesType = types.submodule {
    options = lib.mapAttrs (_: description: lib.mkEnableOption description) {
      jjCiWebhook = "the jj-ci webhook listener, published through Tailscale Funnel";
      nixObservability = "the local OpenTelemetry viewer for Nix traces";
      luvusAutopilot = "the Luvus task dependency watcher";
      paseo = "the Paseo daemon";
      opencodeServer = "the OpenCode HTTP server";
      t3code = "the T3 Code server, an execution environment for the agent fleet";
      rex = "the personal Rex terminal server for the host's home user";
      crossStream = "the system cross.stream service, for hosts without the Home Manager one";
    };
  };

  policyType = types.submodule {
    options = {
      criticality = mkOption {
        type = types.enum [
          "disposable"
          "workstation"
          "critical"
        ];
        default = "workstation";
        description = "Operational impact if this host is unavailable.";
      };
      autoDeploy = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the host stages each landing of main on its own (modules/nixos/fleet/system-switch.nix).";
      };
      requireReview = mkOption {
        type = types.bool;
        default = true;
        description = "Whether changes to this host require human review.";
      };
      rollback = mkOption {
        type = types.bool;
        default = true;
        description = "Whether the deployment workflow must preserve rollback.";
      };
      healthChecks = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Named probes a staged switch runs once the units it touched settle.";
      };
    };
  };

  deployType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether Clan deploys this host (a machine of flake output clan).";
      };
      targetHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "homelab";
        description = ''
          SSH destination Clan pushes to, resolved through the user's ssh
          configuration. null deploys only on the host itself, over ssh to
          localhost.
        '';
      };
      targetUser = mkOption {
        type = types.str;
        default = "root";
        description = ''
          SSH user Clan logs in as; any other user activates through sudo on
          the host.
        '';
      };
      sshPort = mkOption {
        type = types.nullOr types.port;
        default = null;
        example = 2222;
        description = ''
          OpenSSH port on targetHost for unattended logins with keys, such
          as a workstation fetching this canary's reverts. null uses the
          destination's own port.
        '';
      };
    };
  };

  networkType = types.submodule {
    options = {
      tailnet = mkOption {
        type = types.str;
        example = "tail0000.ts.net";
        description = ''
          The Tailscale MagicDNS suffix the host is reachable under, as
          `<host>.<tailnet>`. den/aspects/fleet/fleet-network.nix hands it to the
          host's modules.
        '';
      };
    };
  };

in
{
  config = {
    den.schema.host.imports = [
      {
        options = {
          profile = mkOption {
            type = profileType;
            default = { };
            description = "What the host is used for; the master host resolver reads it.";
          };
          hardware = mkOption {
            type = hardwareType;
            default = { };
            description = "What the machine is; the master host resolver reads it.";
          };
          services = mkOption {
            type = servicesType;
            default = { };
            description = "The long-running services the host runs.";
          };
          policy = mkOption {
            type = policyType;
            default = { };
            description = "Typed safety and deployment policy for this host.";
          };
          deploy = mkOption {
            type = deployType;
            default = { };
            description = "How Clan reaches this host, if it deploys it at all.";
          };
          network = mkOption {
            type = networkType;
            description = "Where the host sits on the network the fleet shares.";
          };
        };
      }
    ];

    den.schema.user.imports = [
      {
        options = {
          environment = mkOption {
            type = types.enum [
              "personal"
              "service"
            ];
            default = "personal";
            description = "The kind of user environment represented by this account.";
          };
          primary = mkOption {
            type = types.bool;
            default = false;
            description = "Whether this is the primary reusable personal environment.";
          };
          home = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Whether the user has a Home Manager home on this host. Where it
              is activated is homeActivation's choice.
            '';
          };
          homeActivation = mkOption {
            type = types.enum [
              "standalone"
              "embedded"
            ];
            default = "standalone";
            description = ''
              Where a user with `home = true` has that home activated.
              `standalone`: flake output homeConfigurations."USER@HOST", which
              `nh home switch` (or home-activate) applies apart from the
              system, for quick, sudo-free iteration on a workstation.
              `embedded`: the Home Manager NixOS module builds the same home
              into the host's system, so it deploys with every switch, as a
              server's should (den/aspects/users/home-manager-host.nix).
            '';
          };
        };
      }
    ];
  };

  options.myConfig.aspectPolicy = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          risk = mkOption {
            type = types.enum [
              "low"
              "medium"
              "high"
              "critical"
            ];
            description = "Change risk associated with this aspect.";
          };
          reviewers = mkOption {
            type = types.listOf types.str;
            description = "Reviewer domains for this aspect.";
          };
        };
      }
    );
    default = { };
    description = "Typed risk and reviewer metadata for configuration aspects.";
  };
}
