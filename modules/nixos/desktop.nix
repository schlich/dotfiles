{ pkgs, ... }:

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

  niriPackage = pkgs.niri.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      rm "$out/bin/niri-session"
      cp ${niriSessionWait}/bin/niri-session "$out/bin/niri-session"
    '';
  });
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
}
