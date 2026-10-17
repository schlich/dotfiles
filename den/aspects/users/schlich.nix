{ den, lib, ... }:
{
  den.aspects.schlich = {
    includes = [
      den.batteries.define-user
      den.aspects.user-core
      den.aspects.user-shell
      # Servers such as homelab get the shell home only. These shape only
      # the standalone home (homeConfigurations."USER@HOST"), so they read
      # the host through the `home` Den binds there.
      (
        { home, ... }:
        lib.optionalAttrs (home.host.profile.role == "workstation") {
          includes = [ den.aspects.user-desktop ];
          # The input stack is declared with the desktop modules.
          homeManager.dotfiles.input.enable = true;
        }
      )
      (
        { home, ... }:
        lib.optionalAttrs home.host.services.nixObservability {
          includes = [ den.aspects.nix-observability-home ];
        }
      )
    ];
    homeManager = {
      home.username = "schlich";
      home.homeDirectory = "/home/schlich";
      home.stateVersion = "26.05";
      # Activation moves a file it would replace aside instead of failing.
      home.backupFileExtension = "hm-backup";
      dotfiles.primary = {
        terminal = "ghostty";
        editor = "helix";
        ai = "opencode";
        desktopAgent = "t3code";
      };
    };
  };
}
