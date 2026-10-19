let
  user = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMx2f7+EO5QZSBDIGw6iyPDGG/aoYx6KIEDoEHjIv/T4 nixos@nixos";
  host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFA2Wd/hVlqxzgbbJS6ogkbMDj0Anq4xlMKLPKDdvmAs root@nixos";

  # asus administers the fleet: its login key can edit and rekey these files
  # with agenix.
  admin = (import ../hosts/login-keys.nix).asus;
  # homelab's OpenSSH host key, which agenix decrypts with at activation.
  homelab = (import ../hosts/homelab/builder.nix).hostKey;
in
{
  "github-token.age".publicKeys = [
    user
    host
  ];
  "flakehub.age".publicKeys = [
    user
    host
  ];

  # nixbot's GitHub App, which nixbot-register writes (docs/nixbot.md).
  "nixbot/github-app.pem.age".publicKeys = [
    admin
    homelab
  ];
  "nixbot/github-webhook-secret.age".publicKeys = [
    admin
    homelab
  ];
  "nixbot/github-oauth-secret.age".publicKeys = [
    admin
    homelab
  ];
}
