let
  # asus administers the fleet: its login key can edit and rekey these files
  # with agenix.
  admin = (import ../hosts/login-keys.nix).asus;
  # homelab's OpenSSH host key, which agenix decrypts with at activation.
  homelab = (import ../hosts/homelab/builder.nix).hostKey;
in
{
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
