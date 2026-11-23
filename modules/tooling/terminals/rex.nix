{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

# Rex, the terminal multiplexer, from its prebuilt snapshot flake: the rex
# command, its xterm-rex terminfo entry in ~/.terminfo, and a personal server
# as the `rex` systemd user service. `loginctl enable-linger` keeps the
# server running while logged out. Agents get what `rex skill setup` would
# install: the rex skill, and a SessionStart hook in Claude Code and Codex.
#
# Rex has no interactive client for Linux yet; Rex.app on macOS is the only
# one released. Here `rex` is the command-line client, and `-S LABEL` sends a
# command to one of the hosts below instead of this machine's server.
let
  cfg = config.dotfiles.rex;
  rex = lib.getExe config.programs.rex.package;
  jq = lib.getExe pkgs.jq;

  # What `rex skill setup` installs, declared instead of written at runtime.
  # The skill is a stub that asks the installed rex for its guide, so it
  # follows Rex upgrades. Session naming stays off, as a plain setup leaves it.
  skill = pkgs.writeTextDir "SKILL.md" ''
    ---
    name: rex
    description: Use the rex CLI to manage Rex sessions, open tabs, arrange panes, run commands, inspect terminal output, and control connected Rex apps.
    metadata:
      rex-stub: "2"
    ---
    <!-- Installed by Home Manager (modules/tooling/terminals/rex.nix). -->

    Run `rex __internal skill --feature-session-naming=false` and follow the guide it prints. The guide comes from
    the installed Rex CLI, so it describes the commands available in that version.

    If the command fails, the installed Rex version predates the guide. Start with
    `rex whoami --json`, then use `rex --help` and `rex COMMAND --help`.
  '';
  # The SessionStart hook tells the agent which Rex session and terminal it
  # runs in. It never fails the session, whether or not a shell runs it.
  sessionStart = pkgs.writeShellScript "rex-session-start" ''
    ${rex} __internal session-start --agent "$1" --feature-session-naming=false 2>/dev/null || true
  '';
  sessionStartHook = agent: extra: {
    hooks = [
      (
        {
          type = "command";
          command = "${sessionStart} ${agent}";
          timeout = 5;
        }
        // extra
      )
    ];
  };
  # Claude Code keeps plugins beside skills in ~/.claude/skills, so the plugin
  # needs a name other than the skill's.
  claudePlugin = pkgs.runCommand "claude-code-rex-session" { } ''
    install -Dm644 ${
      pkgs.writers.writeJSON "plugin.json" {
        name = "rex-session";
        description = "Tell each session which Rex session and terminal it runs in.";
      }
    } $out/.claude-plugin/plugin.json
    install -Dm644 ${
      pkgs.writers.writeJSON "hooks.json" {
        hooks.SessionStart = [ (sessionStartHook "claude" { }) ];
      }
    } $out/hooks/hooks.json
  '';
in
{
  imports = [ inputs.rex.homeManagerModules.default ];

  options.dotfiles.rex.hosts = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    example = {
      homelab = "https://homelab.example.ts.net:7297";
    };
    description = ''
      Other Rex servers to reach by label, as in `rex -S homelab ls`. Rex
      keeps hosts as runtime state on the account's home server, so
      activation adds each missing label there and leaves an existing one
      alone, and `rex hosts edit` keeps working.
    '';
  };

  config = {
    programs.rex = {
      enable = true;
      # The guard needs Home Manager's programs.ssh, which this repository does
      # not use; ssh.nix includes it in the wrapped ssh's config instead.
      sshGuard = false;
    };
    services.rex.enable = true;

    # Claude Code reads the skill from ~/.claude/skills and its hooks from a
    # plugin, since it rewrites settings.json at runtime. Codex and OpenCode
    # share ~/.agents/skills; OpenCode has no command hooks.
    programs.claude-code = lib.mkIf config.programs.claude-code.enable {
      skills.rex = skill;
      plugins.rex-session = claudePlugin;
    };
    home.file.".agents/skills/rex".source = skill;
    programs.codex = lib.mkIf config.programs.codex.enable {
      hooks.SessionStart = [
        (sessionStartHook "codex" { statusMessage = "Loading Rex terminal context"; })
      ];
    };

    # After the switch's own units start, so the server is normally up; when
    # it is not, the hosts wait for the next activation.
    home.activation.rexHosts = lib.mkIf (cfg.hosts != { }) (
      lib.hm.dag.entryAfter [ "reloadSystemd" ] ''
        if known=$(${rex} --autostart=false hosts list --json 2>/dev/null); then
          for entry in ${
            lib.escapeShellArgs (lib.mapAttrsToList (label: endpoint: "${label}=${endpoint}") cfg.hosts)
          }; do
            label=''${entry%%=*}
            endpoint=''${entry#*=}
            if ! ${jq} --exit-status --arg label "$label" \
              'any(.hosts[]; .host.label | ascii_downcase == ($label | ascii_downcase))' \
              <<<"$known" >/dev/null; then
              run ${rex} --autostart=false hosts add "$label" "$endpoint" \
                || warnEcho "rex: could not add host $label ($endpoint)"
            fi
          done
        else
          warnEcho "rex: the Rex server is not running, so hosts were not added: ${lib.concatStringsSep ", " (lib.attrNames cfg.hosts)}"
        fi
      ''
    );

    dotfiles.nixpkgsWatchExempt.rex = "the vendor's prebuilt, closed-source release; nixpkgs' rex is an unrelated Perl tool";
  };
}
