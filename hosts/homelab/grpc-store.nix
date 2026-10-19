# How the fleet reaches homelab's store over gRPC. The certificate is
# Tailscale's for homelab's tailnet name, so clients verify it with the system
# CA bundle; see modules/nixos/homelab-grpc-store.nix.
# Clients reach it at grpc://${config.dotfiles.fleet.hosts.homelab.fqdn}:${port}.
{
  port = 50051;
}
