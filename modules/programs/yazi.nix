{ lib, pkgs, ... }:

let
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  toml = pkgs.formats.toml { };
  glow = lib.getExe pkgs.glow;
in
{
  # `y` browses with Yazi and changes to the directory it was quit in. The
  # module adds `y` and installs the package; YAZI_CONFIG_HOME on the wrapper
  # carries the settings, so Helix's picker gets them too.
  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
    shellWrapperName = "y";
    package = wrapWithConfig {
      package = pkgs.yazi;
      programs = [
        "yazi"
        "ya"
      ];
      env.YAZI_CONFIG_HOME = "${pkgs.linkFarm "yazi-config" [
        {
          name = "yazi.toml";
          path = toml.generate "yazi.toml" {
            mgr = {
              show_hidden = false;
              sort_by = "mtime";
              sort_dir_first = true;
            };
            preview = {
              max_width = 1000;
              max_height = 1000;
            };
            # Markdown previews render through glow (via the piper plugin)
            # instead of bat's raw source view.
            plugin.prepend_previewers = [
              {
                url = "*.{md,markdown,mdx}";
                run = ''piper -- CLICOLOR_FORCE=1 ${glow} --width=$w --style=auto "$1"'';
              }
            ];
            # Enter edits in $EDITOR; `o`/`O` also offers a full-screen
            # glow reader.
            opener.read-markdown = [
              {
                run = ''${glow} --pager "$1"'';
                block = true;
                desc = "Read (glow)";
                for = "unix";
              }
            ];
            open.prepend_rules = [
              {
                url = "*.{md,markdown,mdx}";
                use = [
                  "edit"
                  "read-markdown"
                ];
              }
            ];
          };
        }
        {
          name = "plugins/piper.yazi";
          path = pkgs.yaziPlugins.piper;
        }
        {
          name = "keymap.toml";
          # `g n` goes to the notes, beside the built-in `g h` (home) and
          # `g d` (downloads), matching niri's Mod+N for this area's notes.
          path = toml.generate "yazi-keymap.toml" {
            mgr.prepend_keymap = [
              {
                on = [
                  "g"
                  "n"
                ];
                run = "cd ~/kb";
                desc = "Go to the knowledge base";
              }
            ];
          };
        }
      ]}";
    };
  };

  dotfiles.retiredHomeFiles = [
    ".config/yazi/yazi.toml"
    ".config/yazi/keymap.toml"
  ];
}
