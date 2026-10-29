{
  lib,
  pkgs,
  ...
}:

let
  hokum = import ./hokum-package.nix { inherit lib pkgs; };
in
{
  # Hokum is the notification daemon, with sound and Bluetooth panes and a
  # tray icon. Noctalia's own daemon is off (desktop.nix), so Hokum owns
  # org.freedesktop.Notifications; Noctalia's internal toasts still show.
  # Its settings window edits ~/.config/hokum/config.kdl, so that file stays
  # runtime state.
  home.packages = [ hokum ];

  # Upstream's packaging/hokum.service, with the store path.
  systemd.user.services.hokum = {
    Unit = {
      Description = "Hokum: notifications (org.freedesktop.Notifications), sound and Bluetooth";
      Documentation = "https://hokum.app";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "dbus";
      BusName = "org.freedesktop.Notifications";
      ExecCondition = "${pkgs.runtimeShell} -c '[ -n \"$WAYLAND_DISPLAY\" ]'";
      ExecStart = "${lib.getExe hokum} service";
      Restart = "on-failure";
      # 78: no layer-shell, or another shell keeps the bus name.
      RestartPreventExitStatus = 78;
      RestartSec = 2;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  dotfiles.nixpkgsWatch.hokum = {
    inherit (hokum) version;
    reason = "replace modules/programs/hokum-package.nix with pkgs.hokum in hokum.nix";
  };
}
