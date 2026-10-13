# How the fleet reaches homelab's binary cache. The signing key's secret half
# lives only on homelab; modules/nixos/homelab-cache.nix says how to rotate it.
let
  port = 5000;
in
{
  inherit port;
  url = "http://homelab.tail338351.ts.net:${toString port}";
  publicKey = "homelab-cache-1:iRxSmTDiOFX6oY5jLwiUiXCNJ5KSfHtmJBG7RDzLDaQ=";
}
