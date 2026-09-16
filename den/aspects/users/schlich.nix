{ den, ... }:
{
  den.aspects.schlich = {
    includes = [
      den.batteries.define-user
      den.aspects.user-core
      den.aspects.user-terminal
    ];
    homeManager = {
      home.username = "schlich";
      home.homeDirectory = "/home/schlich";
      home.stateVersion = "26.05";
      dotfiles.primary = {
        terminal = "ghostty";
        editor = "helix";
        ai = "opencode";
      };
    };
  };
}
