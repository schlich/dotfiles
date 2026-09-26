{ inputs, pkgs, ... }:

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
