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
      platform = mkOption {
        type = types.enum [
          "asus"
          "homelab"
        ];
        default = "asus";
        description = "The physical or virtual platform contract for the host.";
      };
      storage = mkOption {
        type = types.enum [
          "internal"
          "usb"
        ];
        default = "internal";
        description = "The host-local storage layout selected for the host.";
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
        description = "Whether the host needs the existing XR integration.";
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
        description = "Whether a future deployment workflow may deploy automatically.";
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
        description = "Named checks a future deployment workflow should run.";
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
            description = "Typed facts used by the host-profile resolver.";
          };
          policy = mkOption {
            type = policyType;
            default = { };
            description = "Typed safety and deployment policy for this host.";
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
