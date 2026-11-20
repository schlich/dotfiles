{
  config,
  lib,
  pkgs,
  ...
}:

let
  vars = config.home.sessionVariables;
in
{
  home.sessionVariables = {
    SHELL = "${pkgs.nushell}/bin/nu";
    NIXOS_OZONE_WL = "1";
  };

  # Home Manager writes home.sessionVariables to hm-session-vars.sh, which
  # Nushell loads through programs.nushell.loadSessionVariables. Forward them
  # to environment.d as well so the systemd user manager, the niri session,
  # and everything it starts (terminals, GUI apps, and agent sessions) inherit
  # them. This is its own file rather than systemd.user.sessionVariables: Home
  # Manager links that one only when the option is non-empty, and the OpenCode
  # module decides OPENCODE_CONFIG by looking up its file in home.file, so
  # forwarding through the option recurses.
  xdg.configFile."environment.d/20-session-variables.conf".text = lib.concatStrings (
    lib.mapAttrsToList (name: value: "${name}=${toString value}\n") vars
  );
}
