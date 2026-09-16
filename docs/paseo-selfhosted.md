# Paseo self-hosted web UI

This flake exposes the unofficial
[Paseo self-hosted web UI](https://github.com/blockfeed/paseo-selfhosted),
which serves the web client and proxies its WebSocket connection to a running
Paseo daemon.

The daemon is not included. It must already be listening on TCP port `6767`,
or you can set `PASEO_DAEMON_HOST` to another `host:port`.

## Run it directly

From this repository:

```text
nix run path:.#paseo-selfhosted
```

The UI is available at `http://localhost:8080`. Override the defaults with
`PASEO_DAEMON_HOST`, `WEBUI_PORT`, or `PASEO_SELFHOSTED_IMAGE`.

## Enable it in NixOS

Import `inputs.self.nixosModules.paseo-selfhosted` into the host and enable the
service:

```nix
{
  imports = [ inputs.self.nixosModules.paseo-selfhosted ];

  services.paseo-selfhosted = {
    enable = true;
    daemonHost = "127.0.0.1:6767";
    port = 8080;
  };
}
```

The module enables Docker, builds the upstream Dockerfile when the service
starts, and keeps the resulting container running with systemd.
