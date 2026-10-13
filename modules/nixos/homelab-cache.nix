{ config, ... }:

let
  cache = import ../../hosts/homelab/cache.nix;
in
{
  # Harmonia serves homelab's whole store: its own system, what spindle guests
  # build, and anything else built here. The secret half of the signing key
  # was generated on the host and never enters the repository or the store;
  # to rotate it, rerun this on homelab and replace publicKey in
  # hosts/homelab/cache.nix with what it prints:
  #   nix key generate-secret --key-name homelab-cache-1 | sudo tee /var/lib/harmonia-secrets/signing-key | nix key convert-secret-to-public
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ "/var/lib/harmonia-secrets/signing-key" ];
    settings.bind = "[::]:${toString cache.port}";
  };

  systemd.tmpfiles.rules = [ "d /var/lib/harmonia-secrets 0700 root root -" ];

  # Spindle guests reach the cache on loopback and the fleet over the tailnet;
  # the LAN and the router never see the port.
  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
    cache.port
  ];
}
