{ den, lib, ... }:
{
  den.aspects.schlich = {
    includes = [
      den.batteries.define-user
      den.aspects.user-core
      den.aspects.user-shell
      # Servers such as homelab get the shell home plus server-side remote
      # editor helpers; desktop pieces stay on workstations. These shape only
      # the home Den resolves as USER@HOST (den/inventory.nix), standalone or
      # embedded in the system, so they read the host through the `home` Den
      # binds there.
      (
        { home, ... }:
        lib.optionalAttrs (home.host.profile.role == "server") {
          includes = [ den.aspects.user-server ];
        }
      )
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
        lib.optionalAttrs home.host.services.rex {
          includes = [ den.aspects.rex-home ];
        }
      )
      (
        { home, ... }:
        lib.optionalAttrs home.host.services.nixObservability {
          includes = [ den.aspects.nix-observability-home ];
        }
      )
      (
        { home, ... }:
        lib.optionalAttrs home.host.services.luvusAutopilot {
          homeManager.dotfiles.luvus.autopilot.enable = true;
        }
      )
      # The T3 Code server runs in the home of the host's one user with a
      # home (den/aspects/services/agent-servers/t3code.nix).
      (
        { home, ... }:
        lib.optionalAttrs home.host.services.t3code {
          includes = [ den.aspects.t3code-home ];
        }
      )
      # Likewise Luvus Web (den/aspects/services/agent-servers/luvus-web.nix).
      (
        { home, ... }:
        lib.optionalAttrs home.host.services.luvusWeb {
          includes = [ den.aspects.luvus-web-home ];
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
