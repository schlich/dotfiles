# OpenSSH with its client configuration named by -F. Claude Desktop runs
# sessions in a user namespace that shows store files, including Home
# Manager's ~/.ssh/config link, as owned by `nobody`, and ssh rejects a user
# config it does not own; -F skips only that ownership check. The sandbox
# also hides host /etc/ssh, so the system config is included rather than
# relied on, and ssh ignores the include when the file is missing.
#
# `includes` go first, ahead of every Host block: a Match block such as Rex's
# TERM guard only works there, and ssh keeps the first value it sees.
{
  lib,
  pkgs,
  includes ? [ ],
}:

let
  wrapWithConfig = import ../../../lib/wrap-with-config.nix { inherit lib pkgs; };
  # asus's login key (hosts/login-keys.nix); the file keeps its old name.
  loginKey = "/home/schlich/.ssh/id_ed25519_tangled";
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
      ${lib.concatMapStrings (file: "Include ${file}\n") includes}
      # homelab's sudo accepts this key from the forwarded agent. Forward it
      # only here: root on the far end can use the agent while connected.
      Host homelab
        IdentityFile ${loginKey}
        IdentitiesOnly yes
        ForwardAgent yes

      Host *
        AddKeysToAgent yes
        Include /etc/ssh/ssh_config
    '')
  ];
}
