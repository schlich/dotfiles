{ ... }:

{
  imports = [
    ./base.nix
    ./codex.nix
    ./desktop.nix
    ./jj-ci-webhook.nix
    ./user.nix
    ./docker.nix
    ./files.nix
  ];

  services.jj-ci-webhook.enable = true;
}
