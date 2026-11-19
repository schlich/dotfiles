{
  config,
  lib,
  pkgs,
  ...
}:

# HEX, dictation that types what you say into the focused field. Its user
# service does not start with the session: Mod+D in niri/binds.nix starts it,
# and from then on HEX hears Mod+D itself. On Wayland it reads the keyboard
# from /dev/input, so its host adds the user to the input group
# (hosts/asus/default.nix). The shortcut, mode, and model live in HEX's own
# settings.json, which its Settings window (`hex app`) writes.
let
  hex = pkgs.anomaly-hex;
  dataDir = "${config.xdg.dataHome}/hex";
in
{
  home.packages = [ hex ];

  systemd.user.services.hex = {
    Unit = {
      Description = "Hex local voice dictation";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      Type = "notify";
      NotifyAccess = "main";
      ExecStart = "${lib.getExe hex} service";
      Environment = [ "HEX_APPLICATION_SUPPORT_DIR=${dataDir}" ];
      # The launcher records the current display environment before starting the unit.
      EnvironmentFile = "-${dataDir}/session.env";
      TimeoutStartSec = 35;
      TimeoutStopSec = 30;
      Restart = "on-failure";
      RestartSec = 5;
      UMask = "0077";
    };
  };
}
