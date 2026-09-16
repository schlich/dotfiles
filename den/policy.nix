{ ... }:
{
  myConfig.aspectPolicy = {
    base = {
      risk = "medium";
      reviewers = [ "nix" ];
    };
    host-profile = {
      risk = "medium";
      reviewers = [ "nix" ];
    };
    workstation = {
      risk = "medium";
      reviewers = [
        "nix"
        "desktop"
      ];
    };
    server = {
      risk = "high";
      reviewers = [
        "nix"
        "networking"
        "security"
      ];
    };
    wsl = {
      risk = "medium";
      reviewers = [ "nix" ];
    };
    desktop-niri = {
      risk = "medium";
      reviewers = [ "desktop" ];
    };
    input-stack = {
      risk = "medium";
      reviewers = [
        "desktop"
        "terminal"
      ];
    };
    laptop = {
      risk = "medium";
      reviewers = [ "desktop" ];
    };
    development = {
      risk = "low";
      reviewers = [ "nix" ];
    };
    remote = {
      risk = "high";
      reviewers = [
        "networking"
        "security"
      ];
    };
    secrets = {
      risk = "critical";
      reviewers = [
        "security"
        "deployment"
      ];
    };
    storage = {
      risk = "critical";
      reviewers = [
        "storage"
        "boot"
      ];
    };
    gpu-amd = {
      risk = "medium";
      reviewers = [
        "desktop"
        "nix"
      ];
    };
    xr = {
      risk = "high";
      reviewers = [
        "desktop"
        "security"
      ];
    };
  };

}
