{
  config,
  inputs,
  ...
}:

let
  grpc = import ../../hosts/homelab/grpc-store.nix;
  tlsDir = "/var/lib/nix-grpc-daemon-tls";
in
{
  imports = [ inputs.nix-grpc-store.nixosModules.server ];

  # nix-grpc-daemon tunnels the Nix worker protocol to the local nix-daemon.
  # With no access rules every client that completes the TLS handshake gets
  # full access, and the default builder role makes the proxy user a trusted
  # Nix user, so the port is open only on the tailnet.
  services.nix-grpc-daemon = {
    enable = true;
    listen = "0.0.0.0:${toString grpc.port}";
    tls = {
      certFile = "${tlsDir}/cert.pem";
      keyFile = "${tlsDir}/key.pem";
    };
  };

  # Tailscale issues homelab's certificate for its tailnet name, so no key
  # enters the repository. The daemon is socket-activated and exits when
  # idle; every start fetches the certificate first, and `tailscale cert`
  # renews it only when it nears expiry.
  systemd.services.nix-grpc-daemon-cert = {
    description = "Fetch nix-grpc-daemon's certificate from Tailscale";
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0750 -o root -g nix-grpc-daemon ${tlsDir}
      ${config.services.tailscale.package}/bin/tailscale cert \
        --cert-file ${tlsDir}/cert.pem \
        --key-file ${tlsDir}/key.pem \
        ${config.dotfiles.fleet.fqdn}
      chgrp nix-grpc-daemon ${tlsDir}/cert.pem ${tlsDir}/key.pem
      chmod 0640 ${tlsDir}/key.pem
    '';
  };

  systemd.services.nix-grpc-daemon = {
    requires = [ "nix-grpc-daemon-cert.service" ];
    after = [ "nix-grpc-daemon-cert.service" ];
  };

  networking.firewall.interfaces.${config.services.tailscale.interfaceName}.allowedTCPPorts = [
    grpc.port
  ];
}
