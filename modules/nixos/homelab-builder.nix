{ config, pkgs, ... }:

let
  builder = import ../../hosts/homelab/builder.nix;
in
{
  # Clients' Nix daemons log in as this account and can only speak the daemon
  # protocol; `restrict` also denies a shell, forwarding, and a terminal.
  users.users.${builder.user} = {
    isSystemUser = true;
    group = builder.user;
    # sshd runs the forced command through the login shell.
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = map (
      key: ''restrict,command="${config.nix.package}/bin/nix-daemon --stdio" ${key}''
    ) builder.clientKeys;
  };
  users.groups.${builder.user} = { };
  services.openssh.settings.AllowUsers = [ builder.user ];

  # Building a client's derivations needs a trusted user. That lets a client
  # add unsigned paths to this store, which Harmonia then signs and serves to
  # the fleet, so a client's root key is as trusted as homelab's own.
  nix.settings.trusted-users = [ builder.user ];
}
