{ config, ... }:

let
  cache = import ../../hosts/homelab/cache.nix;
in
{
  # Harmonia serves homelab's whole store: its own system, what the fleet
  # offloads to its builder, and anything else built here. The secret half of the signing key
  # was generated on the host and never enters the repository or the store;
  # to rotate it, rerun this on homelab and replace publicKey in
  # hosts/homelab/cache.nix with what it prints:
  #   nix key generate-secret --key-name homelab-cache-1 | sudo tee /var/lib/harmonia-secrets/signing-key | nix key convert-secret-to-public
  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ "/var/lib/harmonia-secrets/signing-key" ];
    settings.bind = "[::]:${toString cache.port}";
  };

  # Keep the service running instead of starting it on the first request.
  # switch-to-configuration never restarts a changed socket unit by itself
  # (nixpkgs#74899), only together with an active service; an idle Harmonia
  # left the socket "listening" with no descriptor after its address changed.
  systemd.services.harmonia.wantedBy = [ "multi-user.target" ];

  systemd.tmpfiles.rules = [ "d /var/lib/harmonia-secrets 0700 root root -" ];

  # The fleet reaches the cache over the tailnet; the LAN and the router never
  # see the port.
  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
    cache.port
  ];
}
