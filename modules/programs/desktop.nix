{ config, ... }:

{
  programs = {
    bottom.enable = true;
    herdr.enable = true;
    noctalia = {
      enable = true;
      systemd.enable = true;
      settings = {
        shell = {
          launch_apps_as_systemd_services = true;
          animation.speed = 1.15;
          panel = {
            transparency_mode = "glass";
            borders = true;
            shadow = true;
          };
        };
        wallpaper.default.path = "${config.xdg.dataHome}/wallpapers/niri-navigation.svg";
        system.monitor.enabled = true;

        bar = {
          # Primary navigation and context, kept clear of the system controls.
          default = {
            position = "top";
            thickness = 38;
            margin_ends = 18;
            margin_edge = 10;
            padding = 12;
            widget_spacing = 8;
            background_opacity = 0.86;
            radius = 14;
            shadow = true;
            capsule = true;
            capsule_fill = "surface_variant";
            start = [
              "launcher"
              "wallpaper"
              "workspaces"
            ];
            center = [ "active_window" ];
            end = [
              "media"
              "tray"
              "notifications"
              "clipboard"
            ];
          };

          # A compact telemetry and session strip that does not compete with the task flow above.
          status = {
            position = "bottom";
            thickness = 32;
            margin_ends = 260;
            margin_edge = 10;
            padding = 10;
            widget_spacing = 10;
            background_opacity = 0.82;
            radius = 14;
            shadow = true;
            capsule = true;
            capsule_fill = "surface_variant";
            start = [
              "cpu"
              "memory"
              "network_rx"
              "network_tx"
            ];
            center = [ "clock" ];
            end = [
              "network"
              "bluetooth"
              "volume"
              "brightness"
              "battery"
            ];
          };

          # A right-hand command rail keeps ambient toggles immediately available.
          rail = {
            position = "right";
            thickness = 38;
            margin_ends = 130;
            margin_edge = 10;
            padding = 8;
            widget_spacing = 8;
            background_opacity = 0.82;
            radius = 14;
            shadow = true;
            capsule = true;
            capsule_fill = "surface_variant";
            start = [
              "theme_mode"
              "nightlight"
              "caffeine"
            ];
            center = [ "screenshot" ];
            end = [
              "power_profile"
              "control-center"
              "session"
            ];
          };
        };

        widget = {
          taskbar.show_window_title = true;
          workspaces = {
            # Keep the persistent workspace roles visible and distinguish their state.
            style = "regular";
            show_labels = true;
            label_source = "name";
            max_label_chars = 12;
            pill_scale = 1.0;
            active_pill_size = 2.75;
            inactive_pill_size = 1.15;
            focused_color = "primary";
            occupied_color = "secondary";
            empty_color = "outline";
            urgent_color = "error";
          };
          active_window = {
            max_length = 72;
          };
          cpu = {
            type = "sysmon";
            stat = "cpu_usage";
            visualization = "gauge";
            show_value = true;
          };
          memory = {
            type = "sysmon";
            stat = "ram_pct";
            visualization = "gauge";
            show_value = true;
          };
          network_rx = {
            type = "sysmon";
            stat = "net_rx";
            network_speed_compact = true;
          };
          network_tx = {
            type = "sysmon";
            stat = "net_tx";
            network_speed_compact = true;
          };
        };
      };
    };
    wlogout.enable = true;
  };
}
