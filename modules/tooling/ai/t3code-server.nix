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
# half (modules/nixos/t3code.nix) keeps the user lingering, so it runs from
# boot and survives logout, and publishes it to the tailnet over HTTPS. Nix
# owns the version, so T3's own `t3 service install` and `t3 update` stay
# unused: a second server on ~/.t3 would only be refused by the first one's
# lock. docs/T3-FLEET.md covers pairing, linking and the manual steps.

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
    ${builtins.readFile ./scripts/t3f.nu}
  '';

  # The desktop app and this server cannot both own ~/.t3, so here the app
  # starts without a local environment (Settings → Environments → Local
  # environment) and pairs with the server like any client. The launcher sets
  # that before every start: the app rewrites desktop-settings.json from
  # memory, so a setting made while it runs would not last.
  desktopAsClient = pkgs.writeShellScript "t3code-desktop-as-client" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.coreutils ]}
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
  clientDesktop = pkgs.symlinkJoin {
    name = "t3code-client-${t3code.version}";
    paths = [ t3code ];
    postBuild = ''
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
        Each client signs in once with OAuth (docs/T3-FLEET.md); its token
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
      lib.optional (!config.dotfiles.t3code.desktop.enable) t3code
      # Execution hosts carry Codex even without the desktop's Codex setup
      # (codex.nix); it signs in with `codex login --device-auth`.
      ++ lib.optional (!config.programs.codex.enable) pkgs.codex;
    dotfiles.t3code.desktop.package = clientDesktop;

    systemd.user.services.t3code-server = {
      Unit = {
        Description = "T3 Code server";
        Documentation = [ "https://github.com/pingdotgg/t3code/blob/main/docs/user/background-service.md" ];
        # As upstream's unit: give up after five failed starts in five
        # minutes; `systemctl --user restart` clears it.
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
      Service = {
        ExecStart = "${serve} --host 127.0.0.1 --port ${port} --base-dir ${baseDir}";
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
        Restart = "always";
        RestartSec = "5s";
        # Exit status 78: another server already owns ~/.t3, such as the
        # desktop app's own local environment. Restarting cannot help.
        RestartPreventExitStatus = 78;
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
  };
}
