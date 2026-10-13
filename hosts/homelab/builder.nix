# How the fleet reaches homelab as a remote builder. Tailscale SSH answers
# port 22 on the tailnet address and never reads authorized_keys, so builds
# go to OpenSSH on 2222.
{
  hostName = "homelab.tail338351.ts.net";
  port = 2222;
  hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtCmIzvRPo258IXL6rs+awqFQMVZiFnhYPTnWZf9lO4";
  user = "nix-builder";
  # Each client's key, which the client generates itself and publishes at
  # /run/homelab-builder.pub; see modules/nixos/homelab-builder-client.nix.
  clientKeys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbY5pKgfFnAD7XMOq1eRwXbXGkSE+sSgIcMLXqv4i3p nix-builder@asus"
  ];
}
