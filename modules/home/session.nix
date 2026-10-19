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

  # Home Manager writes home.sessionVariables only to hm-session-vars.sh,
  # which POSIX login shells source and Nushell never does, so forward them.
  #
  # The systemd user manager reads environment.d at login, so the niri
  # session and everything it starts, terminals, GUI apps, and agent
  # sessions, inherit these. This is its own file rather than
  # systemd.user.sessionVariables: Home Manager links that one only when the
  # option is non-empty, and the OpenCode module decides OPENCODE_CONFIG by
  # looking up its file in home.file, so forwarding through the option
  # recurses.
  xdg.configFile."environment.d/20-session-variables.conf".text = lib.concatStrings (
    lib.mapAttrsToList (name: value: "${name}=${toString value}\n") vars
  );

  # Nushell sessions the user manager did not start, such as ssh to homelab,
  # at default priority so a module that sets one of these itself still wins.
  programs.nushell.environmentVariables = lib.mapAttrs (_: lib.mkDefault) vars;
}
