{ ... }:

{
  imports = [
    ../base/base.nix
    ./codex.nix
    ./desktop.nix
    ../fleet/jj-ci-webhook.nix
    ../base/user
    ./docker.nix
    ../base/files.nix
  ];

  services.jj-ci-webhook.enable = true;
}
