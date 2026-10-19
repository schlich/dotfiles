{ pkgs, ... }:

let
  otlpPort = 4318;
in
{
  systemd.services.otel-desktop-viewer = {
    description = "Local OpenTelemetry viewer for Nix traces";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.otel-desktop-viewer}/bin/otel-desktop-viewer --db /var/lib/otel-desktop-viewer/telemetry.duckdb --db-max-size 2GB --host 127.0.0.1 --http ${toString otlpPort} --browser-port 8000 --open-browser=false";
      DynamicUser = true;
      StateDirectory = "otel-desktop-viewer";
      StateDirectoryMode = "0700";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
    };
  };
  # Users' homes point ci's traces here through the nix-observability-home
  # aspect (den/aspects/nix-observability.nix), which names the same port.
}
