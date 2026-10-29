{ config, lib, ... }:

# T3 Code's desktop app, `t3code-desktop`. It sets its own Wayland app ID,
# com.t3tools.T3Code, which niri's agents rules match. On a host that also
# runs the fleet server (t3code-server.nix) the app is that server's client
# rather than a server of its own; docs/T3-FLEET.md describes the setup.

{
  imports = [ ./t3code-package.nix ];

  dotfiles.t3code.desktop.enable =
    config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "t3code";

  home.packages = lib.mkIf config.dotfiles.t3code.desktop.enable [
    config.dotfiles.t3code.desktop.package
  ];
}
