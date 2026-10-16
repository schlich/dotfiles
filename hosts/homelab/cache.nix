# How the fleet reaches homelab's binary cache. The signing key's secret half
# lives only on homelab; modules/nixos/homelab-cache.nix says how to rotate it.
# Clients reach it at config.dotfiles.fleet.hosts.homelab.fqdn.
{
  port = 5000;
  publicKey = "homelab-cache-1:iRxSmTDiOFX6oY5jLwiUiXCNJ5KSfHtmJBG7RDzLDaQ=";
}
