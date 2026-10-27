{
  config,
  inputs,
  lib,
  pkgs,
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

  # The prefix is the multiplexer's leader in the input stack (docs/input.md).
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
in
{
  options.dotfiles.luvus.settings = lib.mkOption {
    type = jsonFormat.type;
    default = { };
    description = ''
      Settings merged into ~/.luvus/config.json at activation. Keys follow
      Luvus's config.json; see src/config.rs in the luvus input.
    '';
  };

  config = {
    dotfiles.luvus.settings = {
      inherit prefix;
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
    # modules/tooling/ai/claude-code.nix.
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
