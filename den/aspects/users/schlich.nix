{ den, lib, ... }:
{
  den.aspects.schlich = {
    includes = [
      den.batteries.define-user
      den.aspects.user-core
      den.aspects.user-shell
      # Servers such as homelab get the shell home only.
      (
        { host, ... }:
        lib.optionalAttrs (host.profile.role == "workstation") {
          includes = [ den.aspects.user-desktop ];
          # The input stack is declared with the desktop modules.
          homeManager.dotfiles.input.enable = true;
        }
      )
    ];
    homeManager = {
      home.username = "schlich";
      home.homeDirectory = "/home/schlich";
      home.stateVersion = "26.05";
      dotfiles.primary = {
        terminal = "ghostty";
        editor = "zed";
        ai = "opencode";
        desktopAgent = "t3code";
      };
    };
  };
}
