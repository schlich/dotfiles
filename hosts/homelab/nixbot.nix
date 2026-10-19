# The GitHub App nixbot on homelab runs as. Both IDs are public. nixbot stays
# off while appId is null; `nixbot-register` creates the App from the manifest
# in modules/nixos/nixbot.nix, writes its IDs here, and encrypts its secrets
# into secrets/nixbot/ for homelab. Landing both turns nixbot on.
# docs/nixbot.md has the steps.
{
  # The App's numeric "App ID".
  appId = 5386637;
  # The App's "Client ID", for logging in to restart or cancel builds.
  oauthId = "Iv23liEReEi3CdI2IIBL";
}
