{
  config,
  lib,
  pkgs,
  osConfig ? { },
  ...
}:

# The T3 Code server of this user: the execution environment that the
# desktop app, the phone, linked environments and outside agents connect to,
# as a systemd user unit on ~/.t3. It listens on loopback only; the system
# half (modules/nixos/services/user-servers/t3code.nix) keeps the user lingering, so it runs from
# boot and survives logout, and publishes it to the tailnet over HTTPS. Nix
# owns the version, so T3's own `t3 service install` and `t3 update` stay
# unused: a second server on ~/.t3 would only be refused by the first one's
# lock. docs/agents/T3-FLEET.md covers pairing, linking and the manual steps.

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.dotfiles.t3code.server;
  t3code = config.dotfiles.t3code.package;
  port = toString cfg.port;
  baseDir = "${config.home.homeDirectory}/.t3";
  local = "http://127.0.0.1:${port}";
  unit = "t3code-server.service";
  jq = lib.getExe pkgs.jq;

  # Agents run their commands in non-interactive bash (`bash -c`), which
  # reads BASH_ENV first. This loads the direnv environment of the command's
  # directory, as an interactive shell's hook would, so a command sees its
  # project's Nix dev shell even though T3 starts agents with its own
  # environment. direnv's allow list still decides which .envrc files load.
  # It acts only for a command string: script wrappers, direnv's own among
  # them, also read BASH_ENV, and loading there would leave direnv nothing to
  # export. direnv evaluates an .envrc in a `bash -c` of its own, with
  # DIRENV_WATCHES and no DIRENV_DIR, and the guard covers the rest.
  bashEnv = pkgs.writeText "t3code-bash-env" ''
    if [ -n "''${BASH_EXECUTION_STRING-}" ] && [ -z "''${T3CODE_DIRENV_HOOK-}" ] \
      && ! { [ -n "''${DIRENV_WATCHES-}" ] && [ -z "''${DIRENV_DIR-}" ]; }; then
      export T3CODE_DIRENV_HOOK=1
      eval "$(${config.programs.direnv.package}/bin/direnv export bash 2>/dev/null)"
      unset T3CODE_DIRENV_HOOK
    fi
  '';

  # `t3 serve` prints a banner with a fresh one-time pairing token, its
  # pairing link and a QR code of it at every start, on stdout with the log.
  # Keep those lines out of the journal and the rest in; the server keeps
  # its PID, so systemd signals it directly.
  serve = pkgs.writeShellScript "t3code-serve" ''
    exec ${t3code}/bin/t3 serve "$@" > >(exec ${lib.getExe pkgs.gnugrep} --line-buffered --invert-match --extended-regexp '^(Connection string|Token|Pairing URL|App link): |[█▀▄]')
  '';

  # What the t3f Nushell commands (scripts/t3f.nu) need to know.
  t3fConfig = (pkgs.formats.json { }).generate "t3f.json" {
    self = cfg.host;
    inherit (cfg) fleet port;
    inherit local unit;
  };
  t3f = pkgs.writeText "t3f.nu" ''
    $env.T3F_CONFIG = "${t3fConfig}"
    ${builtins.readFile ../../scripts/t3f.nu}
  '';

  # The desktop app and this server cannot both own ~/.t3, so here the app
  # starts without a local environment (Settings → Environments → Local
  # environment) and pairs with the server like any client. The launcher sets
  # that before every start: the app rewrites desktop-settings.json from
  # memory, so a setting made while it runs would not last.
  desktopAsClient = pkgs.writeShellScript "t3code-desktop-as-client" ''
    set -euo pipefail
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.diffutils
      ]
    }
    settings="$1"
    if [ -s "$settings" ] && ${jq} -e '.localEnvironmentEnabled == false' "$settings" >/dev/null 2>&1; then
      exit 0
    fi
    mkdir -p "$(dirname "$settings")"
    tmp="$(mktemp "$settings.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    if [ -s "$settings" ]; then
      ${jq} '.localEnvironmentEnabled = false' "$settings" > "$tmp"
      chmod --reference="$settings" "$tmp"
    else
      printf '%s\n' '{"localEnvironmentEnabled":false}' > "$tmp"
    fi
    mv -f "$tmp" "$settings"
  '';
  kbMcpCommand = config.programs.mcp.servers.kb.command or null;
  # T3 Code isolates Antigravity under ~/.t3/userdata/providers/antigravity/<id>/
  # (its own GEMINI_HOME), so those profiles do not read ~/.gemini/config/mcp_config.json.
  # Merge the `kb` MCP server into every existing profile's config/mcp_config.json
  # while preserving any user-added servers.
  syncAntigravityKbMcp = pkgs.writeShellScript "t3code-antigravity-kb-mcp" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    providers_dir="''${T3CODE_HOME:-$HOME/.t3}/userdata/providers/antigravity"
    [ -d "$providers_dir" ] || exit 0
    for profile in "$providers_dir"/*; do
      [ -d "$profile" ] || continue
      cfg="$profile/config/mcp_config.json"
      mkdir -p "$profile/config"
      tmp="$(mktemp "$cfg.XXXXXX")"
      if [ -s "$cfg" ] && ${jq} -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
        ${jq} --arg cmd ${lib.escapeShellArg kbMcpCommand} \
          '.mcpServers = ((.mcpServers // {}) + {kb: {command: $cmd, args: []}})' \
          "$cfg" > "$tmp"
      else
        ${jq} -n --arg cmd ${lib.escapeShellArg kbMcpCommand} \
          '{mcpServers: {kb: {command: $cmd, args: []}}}' > "$tmp"
      fi
      if [ -f "$cfg" ] && cmp -s "$tmp" "$cfg"; then
        rm -f "$tmp"
      else
        mv -f "$tmp" "$cfg"
      fi
    done
  '';
  # The unit owns ~/.t3 here, and the lock on it admits one server: a
  # hand-started `t3 serve`, or a bare `t3`, which also runs one, would lock
  # the unit out until it exits, and dies with its login session. So the
  # profile's `t3` refuses to start a server and points at the unit; every
  # other subcommand, and help, version and completions, passes through.
  # T3_SERVE_FORCE=1 starts one anyway. The unit's own ExecStart calls the
  # unguarded ${t3code}/bin/t3.
  serveGuard =
    real:
    pkgs.writeShellScript "t3" ''
      if [ -z "''${T3_SERVE_FORCE-}" ]; then
        command=
        value=
        for arg in "$@"; do
          if [ -n "$value" ]; then
            value=
            continue
          fi
          case "$arg" in
            -h | --help | -v | --version | --completions | --completions=*) exec ${real} "$@" ;;
            # Flags that take a value; the value is not a subcommand.
            --mode | --port | --host | --base-dir | --dev-url | --bootstrap-fd | --tailscale-serve-port | --log-level) value=1 ;;
            -*) ;;
            *)
              command="$arg"
              break
              ;;
          esac
        done
        case "$command" in
          help | app | pair | auth | environment | browser | project | thread | up | status | service | update | install | uninstall | theme | trace | doctor | policy | triage | connect) ;;
          *)
            echo "t3: ${unit} runs this host's server; use 'systemctl --user restart ${lib.removeSuffix ".service" unit}' (T3_SERVE_FORCE=1 starts another anyway)" >&2
            exit 64
            ;;
        esac
      fi
      exec ${real} "$@"
    '';

  # T3 Code as this home installs it: `t3` behind the serve guard, and the
  # desktop launcher starting the app as the unit's client.
  hostPackage = pkgs.symlinkJoin {
    name = "t3code-host-${t3code.version}";
    paths = [ t3code ];
    postBuild = ''
      rm "$out/bin/t3"
      ln -s ${serveGuard "${t3code}/bin/t3"} "$out/bin/t3"
      rm "$out/bin/t3code-desktop"
      cat > "$out/bin/t3code-desktop" <<EOF
      #!${pkgs.runtimeShell}
      ${desktopAsClient} "\''${T3CODE_HOME:-\$HOME/.t3}/userdata/desktop-settings.json" \
        || echo "t3code-desktop: could not start the app as a client of ${unit}" >&2
      exec ${t3code}/bin/t3code-desktop "\$@"
      EOF
      chmod +x "$out/bin/t3code-desktop"
    '';
    inherit (t3code) meta;
  };

  # With Restart= every failed start enters `failed` and triggers OnFailure=,
  # so the outage unit announces only the first failure of an outage: it
  # leaves this stamp, and clearStamp removes it once a server has answered
  # and stayed up. The notice goes to the journal, to this host's
  # cross.stream store as `t3code.outage`, and to the desktop when there is
  # one; the fleet watch below carries a headless server's outage to the
  # workstations.
  outageStamp = "%t/t3code-server-outage";
  outageNotify = pkgs.writeShellScript "t3code-server-outage" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.libnotify
      ]
    }:${config.home.profileDirectory}/bin:/run/current-system/sw/bin
    stamp="$1"
    [ -e "$stamp" ] && exit 0
    date --iso-8601=seconds > "$stamp"
    result="$(systemctl --user show ${unit} --property=Result --value 2>/dev/null || true)"
    msg="T3 Code server on ${cfg.host} failed (''${result:-unknown}); systemd keeps restarting it. journalctl --user -u ${unit}"
    echo "$msg"
    if command -v xs >/dev/null; then
      xs append "$HOME/.local/share/cross.stream/store" t3code.outage \
        --meta "{\"host\":\"${cfg.host}\",\"result\":\"''${result:-unknown}\"}" >/dev/null 2>&1 || true
    fi
    timeout 10 notify-send --app-name "T3 Code" --urgency critical \
      "T3 Code server down on ${cfg.host}" "$msg" >/dev/null 2>&1 || true
    exit 0
  '';
  # Clears the stamp once the server answers on its port and is still the
  # unit's main process ten seconds later: a hand-started server on the same
  # port answers too, while ours exits 78. Never fails the start, and stays
  # well inside TimeoutStartSec.
  clearStamp = pkgs.writeShellScript "t3code-server-up" ''
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
      ]
    }
    for _ in $(seq 60); do
      if curl --fail --silent --max-time 2 --output /dev/null ${local}/.well-known/t3/environment; then
        sleep 10
        if kill -0 "''${MAINPID:-0}" 2>/dev/null; then rm -f "$1"; fi
        exit 0
      fi
      sleep 1
    done
    exit 0
  '';

  # A workstation polls the other fleet servers' discovery endpoints over the
  # tailnet and announces one that has missed two polls in a row, once, and
  # again when it is back.
  watched = lib.filterAttrs (host: _: host != cfg.host) cfg.fleet;
  fleetWatch = pkgs.writeShellScript "t3code-fleet-watch" ''
    set -u
    PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.curl
        pkgs.libnotify
      ]
    }
    state="$1"
    mkdir -p "$state"
    while [ $# -gt 2 ]; do
      host="$2" url="$3"
      shift 2
      misses="$(cat "$state/$host" 2>/dev/null || echo 0)"
      if curl --fail --silent --max-time 10 --output /dev/null "$url/.well-known/t3/environment"; then
        if [ "$misses" -ge 2 ]; then
          echo "T3 Code server on $host is back"
          timeout 10 notify-send --app-name "T3 Code" "T3 Code server on $host is back" "$url" || true
        fi
        rm -f "$state/$host"
      else
        misses=$((misses + 1))
        echo "$misses" > "$state/$host"
        if [ "$misses" -eq 2 ]; then
          echo "T3 Code server on $host is not answering at $url"
          timeout 10 notify-send --app-name "T3 Code" --urgency critical \
            "T3 Code server down on $host" "$url does not answer; on $host: journalctl --user -u ${unit}" || true
        fi
      fi
    done
  '';
in
{
  imports = [ ./t3code-package.nix ];

  options.dotfiles.t3code.server = {
    enable = mkEnableOption "the T3 Code server as a systemd user unit";
    host = mkOption {
      type = types.str;
      default = osConfig.networking.hostName or "localhost";
      defaultText = lib.literalExpression "osConfig.networking.hostName";
      description = "This host's name among the fleet servers.";
    };
    port = mkOption {
      type = types.port;
      default = osConfig.dotfiles.t3code.port or 3773;
      defaultText = lib.literalExpression "osConfig.dotfiles.t3code.port";
      description = "Loopback port the server listens on; the system half publishes the same port on the tailnet.";
    };
    fleet = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        homelab = "https://homelab.tail0000.ts.net:3773";
      };
      description = "Every fleet server's tailnet URL by host name, for the t3f commands.";
    };
    direnv = mkOption {
      type = types.bool;
      default = config.programs.direnv.enable;
      defaultText = lib.literalExpression "config.programs.direnv.enable";
      description = "Whether agents' bash commands load the direnv environment of their directory.";
    };
    mcp = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether Claude Code and Codex list this server's MCP endpoint as `t3`.
        Each client signs in once with OAuth (docs/agents/T3-FLEET.md); its token
        stays in the client's own credential store.
      '';
    };
    telemetry = mkOption {
      type = types.bool;
      default = true;
      description = "Whether the server sends T3's product usage events (T3CODE_TELEMETRY_ENABLED).";
    };
  };

  config = mkIf cfg.enable {
    # The desktop package carries `t3` too.
    home.packages =
      lib.optional (!config.dotfiles.t3code.desktop.enable) hostPackage
      # Execution hosts carry Codex even without the desktop's Codex setup
      # (codex.nix); it signs in with `codex login --device-auth`.
      ++ lib.optional (!config.programs.codex.enable) pkgs.codex;
    dotfiles.t3code.desktop.package = hostPackage;

    systemd.user.services.t3code-server = {
      Unit = {
        Description = "T3 Code server";
        Documentation = [ "https://github.com/pingdotgg/t3code/blob/main/docs/user/background-service.md" ];
        # Unlike upstream's unit, which gives up after five failed starts in
        # five minutes, never hit the start limit: the backoff below already
        # spaces the attempts out.
        StartLimitIntervalSec = 0;
        OnFailure = [ "t3code-server-outage.service" ];
      };
      Service = {
        ExecStartPre = lib.optional (kbMcpCommand != null) "${syncAntigravityKbMcp}";
        ExecStart = "${serve} --host 127.0.0.1 --port ${port} --base-dir ${baseDir}";
        ExecStartPost = "${clearStamp} ${outageStamp}";
        WorkingDirectory = "%h";
        Environment = [
          # The server prefers the login shell's PATH; this is the fallback,
          # with the profile that carries the agents' CLIs.
          "PATH=${
            lib.concatStringsSep ":" [
              "/run/wrappers/bin"
              "${config.home.profileDirectory}/bin"
              "/etc/profiles/per-user/${config.home.username}/bin"
              "/nix/var/nix/profiles/default/bin"
              "/run/current-system/sw/bin"
            ]
          }"
        ]
        # Bash reads BASH_ENV; the agents' Nushell MCP server, where most of
        # their shell work runs, loads direnv when it sees T3_FLEET_DIRENV
        # (scripts/nu-mcp-config.nu).
        ++ lib.optionals cfg.direnv [
          "BASH_ENV=${bashEnv}"
          "T3_FLEET_DIRENV=1"
        ]
        ++ lib.optional config.services.gnome-keyring.enable "SSH_AUTH_SOCK=%t/gcr/ssh"
        ++ lib.optional (!cfg.telemetry) "T3CODE_TELEMETRY_ENABLED=false";
        # Exit status 78: another server already owns ~/.t3. The desktop app
        # no longer does here (t3code-desktop-as-client turns its local
        # environment off), so it is a hand-started server, which dies with
        # its login session. Keep retrying, backing off from 5 seconds to 2
        # minutes, so the unit takes over within about 2 minutes of that
        # server exiting.
        Restart = "always";
        RestartSec = "5s";
        RestartSteps = 8;
        RestartMaxDelaySec = "2min";
        # As upstream's unit: signal the server first and the rest of its
        # cgroup only if it outlasts the stop timeout. Agents run in scopes of
        # their own (app-t3code-agents-*.slice); the next server stops any it
        # left and resumes their sessions.
        KillMode = "mixed";
        OOMPolicy = "continue";
        CPUWeight = 1000;
        IOWeight = 1000;
        ManagedOOMPreference = "avoid";
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.t3code-server-outage = {
      Unit.Description = "Announce a T3 Code server outage";
      Service = {
        Type = "oneshot";
        ExecStart = "${outageNotify} ${outageStamp}";
      };
    };

    # Only a graphical session starts the watch, so a headless server never
    # runs it.
    systemd.user.services.t3code-fleet-watch = mkIf (watched != { }) {
      Unit = {
        Description = "Announce T3 Code fleet servers that stop answering";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${fleetWatch} %t/t3code-fleet-watch ${
          lib.escapeShellArgs (
            lib.concatLists (
              lib.mapAttrsToList (host: url: [
                host
                url
              ]) watched
            )
          )
        }";
      };
    };
    systemd.user.timers.t3code-fleet-watch = mkIf (watched != { }) {
      Unit = {
        Description = "Poll the T3 Code fleet servers";
        PartOf = [ "graphical-session.target" ];
      };
      Timer = {
        OnActiveSec = "1min";
        OnUnitInactiveSec = "2min";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # Outside agents on this host reach the server over loopback, where T3
    # lets them finish its OAuth sign-in; other hosts' agents use linked
    # environments or the tailnet URL.
    programs.claude-code.mcpServers.t3 = mkIf cfg.mcp {
      type = "http";
      url = "${local}/mcp";
    };
    programs.codex.settings.mcp_servers.t3 = mkIf (cfg.mcp && config.programs.codex.enable) {
      url = "${local}/mcp";
    };

    home.activation.t3codeAntigravityKbMcp = mkIf (kbMcpCommand != null) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${syncAntigravityKbMcp}
      ''
    );

    dotfiles.nushellAutoload.t3f = t3f;

    # The bash hook loads an allowed .envrc and leaves an unallowed one alone.
    # It also stays out of direnv's own shells when direnv runs directly, as
    # the Nushell MCP server runs it: a script wrapper around direnv, and the
    # shell that evaluates the .envrc, which therefore runs once.
    dotfiles.tooling.checks.t3code-bash-env =
      pkgs.runCommand "t3code-bash-env-check"
        {
          nativeBuildInputs = [
            pkgs.bash
            config.programs.direnv.package
          ];
        }
        ''
          export HOME="$TMPDIR/home" XDG_DATA_HOME="$TMPDIR/data" XDG_CONFIG_HOME="$TMPDIR/config"
          mkdir -p "$HOME" allowed blocked
          evaluations="$PWD/evaluations"
          printf 'echo x >> %s\nexport T3CODE_CHECK=loaded\n' "$evaluations" > allowed/.envrc
          echo 'export T3CODE_CHECK=loaded' > blocked/.envrc
          (cd allowed && direnv allow)
          got="$(cd allowed && BASH_ENV=${bashEnv} bash -c 'echo "''${T3CODE_CHECK-}"')"
          test "$got" = loaded
          got="$(cd blocked && BASH_ENV=${bashEnv} bash -c 'echo "''${T3CODE_CHECK-}"')"
          test -z "$got"
          wrapper="$PWD/direnv-wrapper"
          printf '#!%s\nexec %s "$@"\n' ${pkgs.runtimeShell} "$(command -v direnv)" > "$wrapper"
          chmod +x "$wrapper"
          rm -f "$evaluations"
          got="$(cd allowed && BASH_ENV=${bashEnv} "$wrapper" export json | ${jq} -r '.T3CODE_CHECK // empty')"
          test "$got" = loaded
          test "$(wc -l < "$evaluations")" -eq 1
          touch "$out"
        '';

    # The guard refuses to start a server, bare `t3` included, passes every
    # other subcommand through to the real `t3`, and gives way to
    # T3_SERVE_FORCE. A stub stands in for `t3` where a server would start.
    dotfiles.tooling.checks.t3code-serve-guard =
      let
        stub = pkgs.writeShellScript "t3-stub" ''echo "ran: $*"'';
        guard = serveGuard stub;
      in
      pkgs.runCommand "t3code-serve-guard-check" { } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        ${guard} serve 2>err && exit 1
        grep -q 'systemctl --user restart t3code-server' err
        ${guard} --port 3000 serve 2>/dev/null && exit 1
        ${guard} 2>/dev/null && exit 1
        ${guard} --no-browser /tmp 2>/dev/null && exit 1
        test "$(${guard} thread list --json)" = "ran: thread list --json"
        test "$(${guard} --log-level debug status)" = "ran: --log-level debug status"
        test "$(T3_SERVE_FORCE=1 ${guard} serve --port 1)" = "ran: serve --port 1"
        ${hostPackage}/bin/t3 --version > version
        test -s version
        touch "$out"
      '';
  };
}
