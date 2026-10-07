{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  usageResetAlert = pkgs.writeNuScriptBin "usage-reset-alert" (
    builtins.readFile ../../noctalia/usage-reset-alert.nu
  );
  bootPostmortem = pkgs.writeNuScriptBin "boot-postmortem" (
    builtins.readFile ../../postmortem/boot-postmortem.nu
  );
in

{
  # Warn through Noctalia notifications half an hour before a Claude or Codex
  # usage window resets.
  systemd.user.services.usage-reset-alert = {
    Unit.Description = "Notify before Claude or Codex usage resets";
    Service = {
      Type = "oneshot";
      ExecStart = "${usageResetAlert}/bin/usage-reset-alert --lead 30min";
      Environment = [
        "PATH=${
          lib.makeBinPath [
            inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default
            pkgs.libnotify
          ]
        }"
      ];
    };
  };
  systemd.user.timers.usage-reset-alert = {
    Unit.Description = "Check Claude and Codex usage resets every five minutes";
    Timer = {
      OnStartupSec = "1min";
      OnUnitActiveSec = "5min";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  # After an unclean shutdown, announce the system's boot-postmortem report
  # once and offer to open an agent on it in a new terminal.
  systemd.user.services.boot-postmortem-notify = {
    Unit = {
      Description = "Announce a report on an unclean shutdown";
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
    };
    Service = {
      # The notification waits for a click, so do not hold up the session.
      Type = "exec";
      ExecStart = "${bootPostmortem}/bin/boot-postmortem notify";
      Environment = [
        # niri comes from the system; `terminal`, `ai`, and `editor` from the profile.
        "PATH=${
          lib.makeBinPath [ pkgs.libnotify ]
        }:/etc/profiles/per-user/${config.home.username}/bin:/run/current-system/sw/bin"
      ];
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };

  programs = {
    bottom.enable = true;
    herdr.enable = true;
    noctalia = {
      enable = true;
      systemd.enable = true;
      # Upstream's workspaces widget can label pills only by number or name.
      # The patch adds `name_labels`, which the workspace bar below uses for
      # emoji. It is built from source rather than fetched from Noctalia's cache.
      package = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ../../noctalia/workspace-name-labels.patch ];
      });
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
          # Navigation, this workspace's windows, media, and time. Rarely used
          # tools fold into an accordion group that expands on hover.
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
            start = [ "launcher" ];
            center = [ "taskbar" ];
            # dicta's recorder light (programs/dicta.nix) leads, so REC and
            # its keys sit in view.
            end = [
              "schlich/dicta:rec"
              "privacy"
              "media"
              "tray"
              "group:tools"
              "thepunkoff/pomodoro:widget"
              "clock"
            ];
            capsule_group = [
              {
                id = "tools";
                members = [
                  "screenshot"
                  "wallpaper"
                  "theme_mode"
                  "nightlight"
                  "caffeine"
                  "power_profile"
                ];
                accordion = true;
                accordion_direction = "start";
              }
            ];
            # The bar's empty ends open the launcher and scroll through workspaces.
            dead_zone.actions = {
              left = "panel-toggle launcher";
              scroll_up = "exec niri msg action focus-workspace-up";
              scroll_down = "exec niri msg action focus-workspace-down";
            };
          };

          # Named workspaces stack down the left edge, following niri's vertical
          # workspace order.
          workspaces = {
            position = "left";
            thickness = 38;
            margin_ends = 120;
            margin_edge = 10;
            padding = 8;
            widget_spacing = 8;
            background_opacity = 0.86;
            radius = 14;
            shadow = true;
            capsule = false;
            # Unset lanes fall back to Noctalia's default widgets, so clear them.
            start = [ ];
            center = [ "workspaces" ];
            end = [ ];
            dead_zone.actions = {
              scroll_up = "exec niri msg action focus-workspace-up";
              scroll_down = "exec niri msg action focus-workspace-down";
            };
          };

          # Telemetry, AI usage, and the system controls.
          status = {
            position = "bottom";
            thickness = 32;
            margin_ends = 18;
            margin_edge = 10;
            padding = 10;
            widget_spacing = 8;
            background_opacity = 0.82;
            radius = 14;
            shadow = true;
            capsule = true;
            capsule_fill = "surface_variant";
            start = [
              "cpu"
              "cpu_temp"
              "memory"
              "disk"
              "network_rx"
              "network_tx"
            ];
            center = [
              "codex_usage"
              "claude_usage"
              "elrondforwin/opencode-go-usage:bar"
            ];
            end = [
              "notifications"
              "clipboard"
              "network"
              "bluetooth"
              "volume"
              "brightness"
              "battery"
              "session"
            ];
          };
        };

        plugins = {
          enabled = [
            "felipeartur/ai-usagebar"
            "elrondforwin/opencode-go-usage"
            "thepunkoff/pomodoro"
          ];
          source = [
            {
              name = "opencode-go-usage";
              kind = "git";
              location = "https://github.com/kaivalagi/noctalia-opencode-usage-plugin";
              enabled = true;
            }
            {
              name = "community";
              kind = "git";
              location = "https://github.com/noctalia-dev/community-plugins";
              enabled = true;
            }
          ];
        };
        plugin_settings."thepunkoff/pomodoro" = {
          work-duration = 25;
          short-break-duration = 5;
          long-break-duration = 15;
          sessions-before-long-break = 4;
          auto-start-work = false;
          auto-start-breaks = false;
        };

        widget = {
          # Tabbed niri columns hide their windows, so list this workspace's windows.
          taskbar = {
            only_active_workspace = true;
            show_window_title = true;
            window_title_max_width = 140;
            taskbar_max_width = 720;
          };
          privacy.hide_inactive = true;
          workspaces = {
            # A vertical bar has no room for names, and pill_scale cannot widen
            # the pills, so each Johnny Decimal area shows an emoji and keeps
            # its name in the tooltip. Project workspaces fall back to niri's
            # Mod+<digit> number.
            style = "regular";
            show_labels = true;
            label_source = "id";
            name_labels = {
              # `snorkel` is being renamed to `work`; drop it once that lands.
              snorkel = "🤿";
              work = "🤿";
              research = "🔬";
              xr = "🥽";
              nix = "❄️";
              ai = "🤖";
              shell = "🐚";
              career = "💼";
              personal = "🏠";
              inbox = "📥";
            };
            hide_when_empty = true;
            labels_only_when_occupied = true;
            max_label_chars = 13;
            pill_scale = 1.0;
            active_pill_size = 2.75;
            inactive_pill_size = 1.15;
            focused_color = "primary";
            occupied_color = "secondary";
            empty_color = "outline";
            urgent_color = "error";
          };
          codex_usage = {
            type = "felipeartur/ai-usagebar:bar";
            vendor = "openai";
            visualization = "gauge";
            extras = "countdown";
            show_name = true;
          };
          claude_usage = {
            type = "felipeartur/ai-usagebar:bar";
            vendor = "anthropic";
            visualization = "gauge";
            extras = "countdown";
            show_name = true;
          };
          cpu = {
            type = "sysmon";
            stat = "cpu_usage";
            visualization = "graph";
            show_value = true;
          };
          cpu_temp = {
            type = "sysmon";
            stat = "cpu_temp";
            visualization = "none";
            show_value = true;
          };
          disk = {
            type = "sysmon";
            stat = "disk_used_pct";
            path = "/";
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
