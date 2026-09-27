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
  };
}
