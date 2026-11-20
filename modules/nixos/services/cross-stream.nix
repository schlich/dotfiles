{ inputs, pkgs, ... }:

let
  xs = inputs.xs.packages.${pkgs.stdenv.hostPlatform.system}.default;
  # The store every tool defaults to when XS_ADDR is unset; the Home Manager
  # service on workstations serves the same path.
  store = "/home/schlich/.local/share/cross.stream/store";
in
{
  # For hosts without Home Manager: the xs CLI, its Nushell commands, and a
  # store that serves from boot rather than only while the user is logged in.
  environment.systemPackages = [ xs ];

  # Nushell autoloads vendor modules from /usr/share whatever the
  # environment; the XDG_DATA_DIRS entries it also reads are unset over SSH.
  systemd.tmpfiles.rules = [
    "L+ /usr/share/nushell/vendor/autoload/xs.nu - - - - ${inputs.xs}/xs.nu"
  ];

  systemd.services.cross-stream = {
    description = "cross.stream event store";
    wantedBy = [ "multi-user.target" ];
    environment.HOME = "/home/schlich";
    # Handlers and actors the store runs call out to Nushell.
    path = [
      pkgs.nushell
      pkgs.coreutils
    ];
    serviceConfig = {
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p ${store}";
      ExecStart = "${xs}/bin/xs serve ${store}";
      User = "schlich";
      Group = "users";
      WorkingDirectory = "/home/schlich";
      Restart = "on-failure";
      RestartSec = "1s";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };
}
