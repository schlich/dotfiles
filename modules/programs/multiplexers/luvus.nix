{
  config,
  inputs,
  lib,
  pkgs,
  osConfig ? null,
  ...
}:

# Luvus, the agent multiplexer. Its Settings screen rewrites
# ~/.luvus/config.json, so these settings are merged into that file at
# activation instead of linked from the store: the keys declared here win,
# and anything else Luvus or the user saved stays. A running server reads the
# file at start; `systemctl --user restart luvus` picks up a new generation
# sooner. (`luvus server restart` would leave the server outside its unit.)
let
  cfg = config.dotfiles.luvus;
  jsonFormat = pkgs.formats.json { };
  luvus = import ./luvus-package.nix { inherit inputs lib pkgs; };

  # The prefix is the multiplexer's leader in the input stack (docs/desktop/input.md).
  multiplexer = lib.findFirst (
    context: context.implementation == "luvus"
  ) null config.dotfiles.input.contexts;
  prefix = if multiplexer == null then "ctrl+space" else lib.toLower multiplexer.leader;

  # The bottom status row shows the prefix and its key hints on the left and,
  # through this widget, the current mode (`NORMAL · 1 pane · tab 2/4`).
  # Keep the widget there whatever the Settings screen saved.
  modeWidget = ''"core:runtime-status"'';

  # Luvus's Codex integration, as `luvus integration install codex` writes
  # it, with the binary fixed at build time. The name keeps Settings →
  # Integrations reporting it as installed.
  codexHook = pkgs.writeShellScript "luvus-agent-hook" ''
    ${lib.getExe luvus} integration hook codex >/dev/null 2>&1
    exit 0
  '';
  codexHookGroup = {
    type = "command";
    command = "${codexHook}";
    timeout = 5;
  };

  # `luvus task start` for Nushell panes, which reject luvus's POSIX launch
  # line (tools/luvus-task-start.nu). Drop it once luvus launches workers in
  # Nushell syntax itself.
  luvusTaskStart = pkgs.writeNuScriptBin "luvus-task-start" (
    builtins.replaceStrings [ "@luvus@" ] [ (lib.getExe luvus) ] (
      builtins.readFile ../../../tools/luvus-task-start.nu
    )
  );

  # The dependency watcher: starts and merges opted-in task chains when their
  # upstream tasks merge (modules/tooling/ai/scripts/luvus-autopilot.nu).
  # It starts workers through luvus-task-start, which finishes the launch in
  # Nushell panes and bases each worktree on luvus/integration, so a task
  # sees the dependencies the watcher merged.
  autopilotScript = ../../tooling/ai/scripts/luvus-autopilot.nu;
  luvusAutopilot = pkgs.writeNuScriptBin "luvus-autopilot" (
    builtins.replaceStrings
      [ "@luvus@" "@taskStart@" "@notifySend@" "@flock@" ]
      [
        (lib.getExe luvus)
        "${luvusTaskStart}/bin/luvus-task-start"
        (lib.getExe' pkgs.libnotify "notify-send")
        (lib.getExe' pkgs.util-linux "flock")
      ]
      (builtins.readFile autopilotScript)
  );
  autopilotExe = "${luvusAutopilot}/bin/luvus-autopilot";
  # `luvus-auto ID` marks a task for the watcher; `luvus-auto --off ID`
  # unmarks it, and its downstream tasks unless they are marked themselves.
  luvusAuto = pkgs.writeNuScriptBin "luvus-auto" ''
    # Mark luvus task ID for the autopilot, or unmark it with --off.
    def main [id: string, --off] {
      ^${autopilotExe} mark $id ...(if $off { [--off] } else { [] })
    }
  '';
  # Luvus shows only bar widgets a module declares, so this module declares
  # the watcher's mode widget; clicking its mode segment pauses or resumes.
  # The service links it into Luvus's module registry.
  autopilotModule = pkgs.runCommand "luvus-autopilot-module" { } ''
    mkdir "$out"
    cp ${
      (pkgs.formats.toml { }).generate "luvus-module.toml" {
        id = "dotfiles.autopilot";
        name = "Autopilot";
        version = "0.1.0";
        min_luvus_version = "0.11.0";
        description = "Mode and worker counts of the luvus-autopilot dependency watcher.";
        platforms = [ "linux" ];
        bars = [
          {
            id = "autopilot";
            title = "Autopilot";
            region = "bottom-right";
            priority = 40;
          }
        ];
        # Bar content does not survive a server restart; repaint it.
        startup = [
          {
            command = [
              autopilotExe
              "bar"
            ];
          }
        ];
        actions = [
          {
            id = "toggle";
            title = "Pause or resume the autopilot";
            command = [
              autopilotExe
              "toggle"
            ];
          }
        ];
      }
    } "$out/luvus-module.toml"
  '';
in
{
  options.dotfiles.luvus.autopilot.enable = lib.mkOption {
    type = lib.types.bool;
    # Den's inventory has no profile field for this yet, and this task may
    # not touch den/; replace the hostname test with one when it does.
    default = (if osConfig == null then null else osConfig.networking.hostName or null) == "asus";
    defaultText = lib.literalExpression ''osConfig.networking.hostName == "asus"'';
    description = ''
      Run luvus-autopilot, which starts and merges luvus tasks marked with
      `luvus-auto ID` and the tasks downstream of them.
    '';
  };

  options.dotfiles.luvus.settings = lib.mkOption {
    type = jsonFormat.type;
    default = { };
    description = ''
      Settings merged into ~/.luvus/config.json at activation. Keys follow
      Luvus's config.json; see src/config.rs in the luvus input.
    '';
  };

  config = {
    dotfiles.nixpkgsWatch.luvus = {
      reason = "replace modules/programs/multiplexers/luvus-package.nix (the luvus input's package, rewrapped so its runtime tools follow PATH instead of leading it) with pkgs.luvus, rewrapping that too if its wrapper prepends, and drop the luvus input; drop each patch in luvus-patches/ once the locked luvus contains its pull request (#546 Nushell worker launch, #551 remote scripts under sh)";
      fix = "https://github.com/RizRiyz/luvus/pull/546";
    };

    # After the prefix, the honeycomb's keys (lib/honeycomb/README.md). Luvus
    # already puts panes on H, L, J and K; these move tabs to Y and U, the
    # keys under the tab bar, and workspaces to N and M. Rebinding a command
    # drops its other default keys, and the two commands that held Y and M
    # move to their capitals' neighbours.
    dotfiles.input.navigation.multiplexer = lib.mkIf (multiplexer != null) (
      lib.mapAttrs (_: key: [ "${multiplexer.leader}+${key}" ]) {
        w = "H";
        e = "L";
        down = "J";
        up = "K";
        nw = "Y";
        ne = "U";
        sw = "N";
        se = "M";
      }
    );

    dotfiles.luvus.settings = {
      inherit prefix;
      keybindings = {
        prev_tab = "y";
        next_tab = "u";
        prev_node = "n";
        next_node = "m";
        copy_mode = "C";
        open_mission = "O";
      };
      # Follow Ghostty's palette, as the editor and shell do.
      theme = "terminal";
      language = "en";
      shell = lib.getExe config.programs.nushell.package;
      # Nix pins Luvus; an update indicator could not be acted on.
      check_updates = false;
      # A replayed `--permission-mode` outlives the session it was meant for.
      resume_launch_flags = false;
      allow_nested = false;
      commander_working_policy = "auto_send";
      session.persist_pane_screen = true;
      worktree.provider = "git";
      notifications = {
        sound_style = "soft";
        sound_on_done = false;
        sound_on_blocked = true;
      };
      layout = {
        show_titles = true;
        pane_title_path = true;
        agent_title = true;
        workspace_paths = true;
        agent_paths = true;
        resume_in_new_workspace = true;
        new_pane_to_workspace_root = false;
        # A file opens in a pane, so in Helix; the primary editor may be a GUI.
        file_open =
          if config.programs.helix.enable then lib.getExe config.programs.helix.package else "readonly";
        file_click = "preview";
        files_show_hidden = true;
        scrollback_bytes = 10 * 1024 * 1024;
        diff_layout = "auto";
        diff_wrap = false;
        diff_context_lines = 3;
        diff_show_line_numbers = true;
        diff_marker_style = "symbols";
        diff_color_mode = "theme";
        diff_live_refresh = true;
        # Ghostty speaks the Kitty keyboard protocol; this is the fallback.
        shift_enter = "esc-cr";
      };
    };

    home.activation.luvusSettings = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
      # Luvus keeps its state directory owner-only.
      if [[ ! -e "$HOME/.luvus" ]]; then
        run mkdir -m 700 "$HOME/.luvus"
      fi
      ${lib.hm.generators.mkImpureConfigMerger {
        inherit pkgs;
        format = "json";
        empty = "{}";
        jqOperation = ''
          $dynamic * $static
          | .bars |= (. // {})
          | .bars.top_right = ((.bars.top_right // []) - [${modeWidget}])
          | .bars.off = ((.bars.off // []) - [${modeWidget}])
          | .bars.bottom_right = ([${modeWidget}] + ((.bars.bottom_right // []) - [${modeWidget}]))
        '';
        path = "${config.home.homeDirectory}/.luvus/config.json";
        staticSettings = jsonFormat.generate "luvus-config.json" cfg.settings;
        mode = "600";
      }}
    '';

    home.packages = [
      luvusTaskStart
    ]
    ++ lib.optionals cfg.autopilot.enable [
      luvusAutopilot
      luvusAuto
    ];

    # Opt-in task chains: wake on `luvus events`, every five minutes, and at
    # start; each pass rereads the board, so it acts at most once per change.
    # Pause with `luvus-autopilot pause` or by clicking the bar widget.
    systemd.user.services.luvus-autopilot = lib.mkIf cfg.autopilot.enable {
      Unit = {
        Description = "Start and merge opted-in luvus task chains";
        After = [ "luvus.service" ];
      };
      Service = {
        ExecStart = "${autopilotExe} run --module ${autopilotModule}";
        # luvus-task-start runs git; the rest is the user's own profile.
        Environment = [
          "PATH=${
            lib.makeBinPath [
              pkgs.git
              pkgs.coreutils
            ]
          }:%h/.nix-profile/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
        ];
        Restart = "always";
        RestartSec = "10s";
      };
      Install.WantedBy = [ "default.target" ];
    };

    # The watcher's decisions against fixture boards, without a server.
    dotfiles.tooling.checks.luvus-autopilot =
      pkgs.runCommand "luvus-autopilot-check" { nativeBuildInputs = [ pkgs.nushell ]; }
        ''
          export HOME="$TMPDIR/home"
          mkdir -p "$HOME"
          nu --no-config-file ${../../tooling/ai/tests/luvus-autopilot.nu} ${autopilotScript}
          touch "$out"
        '';

    # The server owns every pane, agent, task, and path lease. `luvus server
    # start` forks this same command into the background; running it here
    # starts it at login. Its panes inherit the user manager's PATH and SHELL,
    # as they would from a terminal.
    systemd.user.services.luvus = {
      Unit = {
        Description = "Luvus server for coding agents";
        # Stopping the server stops its panes and the agents in them, so an
        # activation that changes this unit leaves the running server alone.
        X-SwitchMethod = "keep-old";
      };
      Service = {
        ExecStart = "${lib.getExe luvus} --session default server";
        # `luvus server stop` exits cleanly and stays stopped.
        Restart = "on-failure";
        RestartSec = "2s";
      };
      Install.WantedBy = [ "default.target" ];
    };

    # Claude Code reports to Luvus through the luvus plugin in
    # modules/tooling/ai/claude/claude-code.nix.
    programs.codex = lib.mkIf config.programs.codex.enable {
      hooks = {
        SessionStart = [
          {
            matcher = "startup|resume";
            hooks = [ codexHookGroup ];
          }
        ];
        UserPromptSubmit = [ { hooks = [ codexHookGroup ]; } ];
      };
      # Luvus's bundled skill, matched to the installed binary. Claude Code's
      # skills/luvus directory already holds the luvus hook plugin.
      skills.luvus = "${inputs.luvus}/skills/luvus";
    };
    programs.opencode.skills = lib.mkIf config.programs.opencode.enable {
      luvus = "${inputs.luvus}/skills/luvus";
    };
  };
}
