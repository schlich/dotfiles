{ pkgs, ... }:

{
  environment.systemPackages = [ pkgs.opencode ];

  systemd.services.opencode-server = {
    description = "OpenCode HTTP server";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      HOME = "/home/schlich";
      XDG_CONFIG_HOME = "/home/schlich/.config";
    };
    serviceConfig = {
      ExecStart = "${pkgs.opencode}/bin/opencode serve --hostname 127.0.0.1 --port 4096";
      User = "schlich";
      Group = "users";
      WorkingDirectory = "/home/schlich";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}
