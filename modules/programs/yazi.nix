{ ... }:

{
  # `y` browses with Yazi and changes to the directory it was quit in.
  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
    shellWrapperName = "y";
    settings = {
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
    # `g n` goes to the notes, beside the built-in `g h` (home) and `g d`
    # (downloads), matching niri's Mod+N for this area's notes.
    keymap.mgr.prepend_keymap = [
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
