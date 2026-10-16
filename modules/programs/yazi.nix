{ lib, pkgs, ... }:

let
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  toml = pkgs.formats.toml { };
  mdcat = lib.getExe' pkgs.mdcat "mdcat";

  # mdcat wraps paragraphs, lists, and quotes with hanging indents, draws
  # tables, and highlights code in the terminal's own palette. Yazi's ANSI
  # parser drops the rest of a line after an OSC 8 hyperlink, so the link
  # escapes are stripped and links show as coloured text.
  markdownPreview = pkgs.writeShellApplication {
    name = "yazi-markdown-preview";
    runtimeInputs = [
      pkgs.mdcat
      pkgs.gnused
    ];
    text = ''
      mdcat --ansi --columns "$1" "$2" | sed 's/\x1b]8;[^\x1b]*\x1b\\//g'
    '';
  };
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
              # Parent, current, and preview columns; the preview gets the
              # widest share so rendered Markdown wraps less.
              ratio = [
                1
                3
                4
              ];
            };
            preview = {
              max_width = 1000;
              max_height = 1000;
            };
            # Markdown previews render through mdcat (via the piper plugin)
            # instead of bat's raw source view. piper scrolls them with the
            # usual preview keys.
            plugin.prepend_previewers = [
              {
                url = "*.{md,markdown,mdx}";
                run = ''piper -- ${lib.getExe markdownPreview} "$w" "$1"'';
              }
            ];
            # Enter edits in $EDITOR; `o`/`O` also offers a full-screen
            # mdcat reader in the pager.
            opener.read-markdown = [
              {
                run = ''${mdcat} --paginate "$1"'';
                block = true;
                desc = "Read (mdcat)";
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
