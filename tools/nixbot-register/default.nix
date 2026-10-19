# `nix run path:.#nixbot-register`, on asus in a topic workspace: creates
# nixbot's GitHub App from homelab's manifest and writes its IDs and
# encrypted secrets into the checkout (docs/nixbot.md). `registration` is
# homelab's config.dotfiles.nixbot.registration. jj, gh, and nix-instantiate
# come from the user's profile, signed in as they are there.
{ pkgs, registration }:
pkgs.writeShellApplication {
  name = "nixbot-register";
  runtimeInputs = [
    pkgs.age
    pkgs.nushell
    pkgs.python3
    pkgs.xdg-utils
  ];
  text = ''
    exec nu --no-config-file ${./register.nu} \
      --registration ${registration} \
      --listener ${./listen.py} \
      "$@"
  '';
  meta.description = "Create nixbot's GitHub App and store its IDs and secrets for homelab";
}
