{
  lib,
  ...
}:
let
  inherit (lib) mkOption types;

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
        description = "Whether the host stages each landing of main on its own (modules/nixos/system-switch.nix).";
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
        description = "Named probes a staged switch watches besides failed units, journal errors, and restart loops.";
      };
      watchDuration = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        example = 45;
        description = ''
          Seconds a staged switch must stay healthy before it becomes the boot
          default, overriding the criticality default. Keep it at least the
          watch's failures times its interval, or no breach can revert it.
        '';
      };
    };
  };

  deployType = types.submodule {
    options = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether Colmena deploys this host (flake output colmenaHive).";
      };
      targetHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "homelab";
        description = ''
          SSH destination Colmena pushes to, resolved through the user's ssh
          configuration. null deploys only on the host itself with
          `colmena apply-local`.
        '';
      };
      targetUser = mkOption {
        type = types.str;
        default = "root";
        description = ''
          SSH user Colmena logs in as; any other user activates through
          non-interactive sudo on the host.
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
          `<host>.<tailnet>`. den/aspects/fleet-network.nix hands it to the
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
            description = "Typed facts used by the master host resolver.";
          };
          policy = mkOption {
            type = policyType;
            default = { };
            description = "Typed safety and deployment policy for this host.";
          };
          deploy = mkOption {
            type = deployType;
            default = { };
            description = "How Colmena reaches this host, if it deploys it at all.";
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
