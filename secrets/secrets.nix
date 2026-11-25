let
  # asus administers the fleet: its login key can edit and rekey these files
  # with agenix.
  admin = (import ../hosts/login-keys.nix).asus;
  # homelab's OpenSSH host key, which agenix decrypts with at activation.
  homelab = (import ../hosts/homelab/builder.nix).hostKey;
in
{
  # nixbot's GitHub App, which nixbot-register writes (docs/delivery/nixbot.md).
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

  # discord-digest's DISCORD_TOKEN= and ANTHROPIC_API_KEY= lines
  # (modules/nixos/homelab/discord-digest.nix).
  "discord-digest/env.age".publicKeys = [
    admin
    homelab
  ];

  # OmniRoute's optional environmentFile (JWT_SECRET, API_KEY_SECRET,
  # OMNIROUTE_WS_BRIDGE_SECRET, etc.; modules/nixos/services/agent-servers/omniroute.nix).
  "omniroute/env.age".publicKeys = [
    admin
    homelab
  ];

  # Executor's optional environmentFile (BETTER_AUTH_SECRET,
  # EXECUTOR_ENCRYPTION_KEY, etc.; modules/nixos/services/agent-servers/executor.nix).
  "executor/env.age".publicKeys = [
    admin
    homelab
  ];
}
