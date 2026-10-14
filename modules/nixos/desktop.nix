{
  config,
  lib,
  pkgs,
  ...
}:

let
  niriSessionWait = pkgs.writeShellScriptBin "niri-session" ''
    # greetd can start the session a fraction before the user manager is ready.
    # Wait for the user manager's D-Bus endpoint before starting the compositor
    # service. Starting the service is important because it also reaches
    # graphical-session.target, which starts Noctalia and other session units.
    for attempt in $(seq 1 100); do
      if systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user reset-failed
        systemctl --user import-environment
        if command -v dbus-update-activation-environment >/dev/null 2>&1; then
          dbus-update-activation-environment --all
        fi
        systemctl --user --wait start niri.service

        # Mirror upstream niri-session: stop graphical-session.target so its
        # units, including Noctalia, start again with the next login.
        systemctl --user start --job-mode=replace-irreversibly niri-shutdown.target
        systemctl --user unset-environment WAYLAND_DISPLAY DISPLAY XDG_SESSION_ID XDG_SESSION_TYPE XDG_CURRENT_DESKTOP NIRI_SOCKET
        exit 0
      fi
      sleep 0.1
    done

    # Keep the session usable if the user manager does not become ready.
    exec ${pkgs.niri}/bin/niri --session
  '';

  # Swap the script in a symlink farm: overriding niri's own build would
  # recompile it instead of using the binary cache.
  niriPackage = pkgs.symlinkJoin {
    name = "niri-${pkgs.niri.version}";
    paths = [ pkgs.niri ];
    # providedSessions is read by the display manager, niri-flake's module
    # reads the cargo feature attributes to decide on the GNOME portal, and the
    # homelab config reads src for niri's default config.
    passthru = pkgs.niri.passthru // {
      inherit (pkgs.niri) cargoBuildNoDefaultFeatures cargoBuildFeatures src;
    };
    inherit (pkgs.niri) meta;
    postBuild = ''
      rm "$out/bin/niri-session"
      cp ${niriSessionWait}/bin/niri-session "$out/bin/niri-session"
    '';
  };
in

{
  services = {
    power-profiles-daemon.enable = true;
    upower.enable = true;
  };

  programs = {
    niri = {
      enable = true;
      package = niriPackage;
    };
    noctalia.enable = true;
  };

  services.displayManager.noctalia-greeter.enable = true;
  # Upstream's greeter module hands the greeter the installed sessions on
  # XDG_DATA_DIRS; nixpkgs' does not, so pass them here.
  services.greetd.settings.default_session.command = lib.concatStringsSep " " [
    (lib.getExe' pkgs.coreutils "env")
    "XDG_DATA_DIRS=${config.services.displayManager.sessionData.desktops}/share"
    (lib.getExe' config.services.displayManager.noctalia-greeter.package "noctalia-greeter-session")
  ];

  # niri falls back to /etc/niri/config.kdl when ~/.config/niri/config.kdl is
  # absent, and reloads it when a switch moves /etc/static. Its binds run the
  # niri-desk commands Home Manager installs (modules/home/files.nix).
  # homelab sets its own config, which takes precedence over this default.
  environment.etc."niri/config.kdl".source = lib.mkDefault ../../niri/config.kdl;
}
