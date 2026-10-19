{
  config,
  inputs,
  pkgs,
  ...
}:

let
  # The knot's hostname is also its did:web identity, and tangled.org reaches
  # it over HTTPS on 443. The knot joins the tailnet as its own node, `knot`,
  # and takes 443 on that name through Funnel, which keeps its did:web
  # identity independent of homelab's own tailnet name.
  hostname = "knot.${config.dotfiles.fleet.tailnet}";
  listenAddr = "127.0.0.1:5555";
  # homelab's OpenSSH holds 22 and 2222, and the second tailscaled forwards
  # each tailnet port to the same loopback port, so the knot needs its own.
  sshAddr = "127.0.0.1:2223";

  # A second tailscaled beside homelab's own. Userspace networking keeps it
  # off the kernel's routing tables, which the first tailscaled owns; it
  # proxies Funnel traffic and inbound tailnet connections (ssh on 2223) to
  # loopback, so nothing here opens a firewall port.
  stateDir = "/var/lib/tailscale-knot";
  socket = "/run/tailscale-knot/tailscaled.sock";
  tailscale = "${pkgs.tailscale}/bin/tailscale --socket=${socket}";

  # Secrets are created on homelab by hand and never enter the repository or
  # the store:
  #   knot.env          KNOT_MASTER_KEY=<openssl rand -base64 32>; back it up
  #                     off the host, since it unseals the knot's signing keys
  #   tailscale-authkey a Tailscale auth key for the `knot` node, needed only
  #                     until its first login
  secretsDir = "/var/lib/knot-secrets";
in
{
  imports = [ inputs.tangled.nixosModules.knot-rs ];

  services.tangled.knot-rs = {
    enable = true;
    environmentFile = "${secretsDir}/knot.env";
    settings = {
      server = {
        inherit hostname;
        # The first admin is the owner the knot advertises; it must be the
        # account DID that registers the knot on tangled.org.
        admins = [ "did:plc:cnyy2sz5ddr4gls245vjgbrd" ];
        listen_addr = listenAddr;
        ssh_listen_addr = sshAddr;
      };
      atproto.plc_directory = "https://plc.directory";
      # Jujutsu's Git backend cannot read SHA-256 repositories, so keep the
      # format every existing clone uses.
      git.object_format = "sha1";
    };
  };

  systemd.tmpfiles.rules = [ "d ${secretsDir} 0700 root root -" ];

  systemd.services.tailscaled-knot = {
    description = "Tailscale node for the Tangled knot";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.tailscale}/bin/tailscaled --tun=userspace-networking --statedir=${stateDir} --socket=${socket} --port=0";
      StateDirectory = "tailscale-knot";
      RuntimeDirectory = "tailscale-knot";
      Restart = "on-failure";
    };
  };

  # Logs the node in (with the auth key while it exists, from saved state
  # afterwards) and serves the knot on https://${hostname}. Funnel needs the
  # tailnet's funnel node attribute for this node; until the key and the
  # attribute exist this unit fails without affecting the knot itself.
  systemd.services.tailscale-knot-funnel = {
    description = "Tailscale Funnel for the Tangled knot";
    wantedBy = [ "multi-user.target" ];
    after = [
      "tailscaled-knot.service"
      "knot-rs.service"
    ];
    requires = [ "tailscaled-knot.service" ];
    path = [ pkgs.tailscale ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStop = "${tailscale} funnel reset";
    };
    script = ''
      key=${secretsDir}/tailscale-authkey
      if [ -e "$key" ]; then
        ${tailscale} up --hostname=knot --accept-dns=false --auth-key="file:$key"
      else
        ${tailscale} up --hostname=knot --accept-dns=false
      fi
      ${tailscale} funnel --bg http://${listenAddr}
    '';
  };
}
