{ ... }:

{
  programs = {
    yazelix.enable = true;
    bottom.enable = true;
    herdr.enable = true;
    noctalia = {
      enable = true;
      systemd.enable = true;
      settings = {
        shell.launch_apps_as_systemd_services = true;
        widget.taskbar.show_window_title = true;
        bar.default.start = [
          "launcher"
          "wallpaper"
          "taskbar"
        ];
      };
    };
    wlogout.enable = true;
  };
}
