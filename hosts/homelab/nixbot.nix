# The GitHub App nixbot on homelab builds the mirror with. Both IDs are public;
# the App's private key, webhook secret, and OAuth client secret live only in
# /var/lib/nixbot-secrets on homelab (modules/nixos/nixbot.nix). nixbot stays
# off while appId is null. homelab deploys every landing of main, so put the
# secrets in place before landing the IDs: a nixbot that cannot load them
# fails its unit, and the staged switch reverts. docs/nixbot.md has the steps.
{
  # The App's numeric "App ID".
  appId = null;
  # The App's "Client ID", for logging in to restart or cancel builds.
  oauthId = null;
}
