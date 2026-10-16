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

  # ci sends each dispatch and landing to the viewer as a trace when the run
  # ends; `ci trace export` sends the ones recorded before.
  home-manager.sharedModules = [
    {
      imports = [ ../programs/ci.nix ];
      dotfiles.ci.tracesEndpoint = "http://127.0.0.1:${toString otlpPort}/v1/traces";
    }
  ];
}
