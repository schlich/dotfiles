# OpenSSH with its client configuration named by -F. Claude Desktop runs
# sessions in a user namespace that shows store files, including Home
# Manager's ~/.ssh/config link, as owned by `nobody`, and ssh rejects a user
# config it does not own; -F skips only that ownership check. The sandbox
# also hides host /etc/ssh, so the system config is included rather than
# relied on, and ssh ignores the include when the file is missing.
{ lib, pkgs }:

let
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  tangledKey = "/home/schlich/.ssh/id_ed25519_tangled";
in
wrapWithConfig {
  package = pkgs.openssh;
  programs = [
    "ssh"
    "scp"
    "sftp"
  ];
  flags = [
    "-F"
    (pkgs.writeText "ssh_config" ''
      Host tangled.org
        HostName tangled.org
        User git
        IdentityFile ${tangledKey}
        IdentitiesOnly yes
        AddressFamily inet

      # homelab's sudo accepts this key from the forwarded agent. Forward it
      # only here: root on the far end can use the agent while connected.
      Host homelab
        IdentityFile ${tangledKey}
        IdentitiesOnly yes
        ForwardAgent yes

      Host *
        AddKeysToAgent yes
        Include /etc/ssh/ssh_config
    '')
  ];
}
