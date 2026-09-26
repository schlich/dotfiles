{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  tomlFormat = pkgs.formats.toml { };
in

{
  imports = [ inputs.yazelix.homeManagerModules.default ];

  # Full Yazelix: Rio, managed Helix, and bundled Yazi. The bundled Yazi is
  # exposed as `yzx-yazi`; nushell/yazelix.nu maps `yazi` and `y` onto it so
  # the same Yazi and config are used outside Yazelix sessions.
  programs.yazelix = {
    enable = true;
    # The module defaults to the stable-channel build even from the edge
    # source; the channel badge and desktop entry come from the package.
    package = inputs.yazelix.packages.${pkgs.stdenv.hostPlatform.system}.yazelix-edge;
    # Sparse root config.toml; absent keys keep packaged defaults. Home Manager
    # owns this file, so `yzx config` shows these settings as declarative and
    # cannot save edits to it.
    config.settings = {
      # gh dash filters to the current repository when opened inside one.
      popups.gh_dash = {
        command = lib.getExe config.programs.gh.package;
        args = [ "dash" ];
        title = "gh_dash";
        keybinding = "Alt Shift D";
        keep_alive = true;
      };
    };
    # Merged over Yazelix's packaged yazi.toml, which keeps its opener rules.
    config.yazi.config.source = tomlFormat.generate "yazelix-yazi.toml" {
      mgr = {
        show_hidden = false;
        sort_by = "mtime";
        sort_dir_first = true;
      };
      preview = {
        max_width = 1000;
        max_height = 1000;
      };
    };
  };
}
