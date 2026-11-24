# The HTTPS ports this host's Tailscale node publishes. Serve and Funnel
# share one port space per node, and Funnel only accepts 443, 8443 and
# 10000, so a module that publishes through either claims its port here and
# reads it back; evaluation fails when two claims collide. Each module that
# claims a port imports this one. A service that runs its own tailscaled
# is a separate node and claims nothing here.
#
# A unit that runs `tailscale serve` at start puts waitForBackend in its
# ExecStartPre, and invokes Serve or Funnel through `serve` below. An
# activation that changes the tailscale package restarts tailscaled and every
# Serve/Funnel unit together: without waitForBackend they exit before the
# daemon is back, and without `serve` they race on /localapi/v0/serve-config
# and fail with "Preconditions failed: etag mismatch", reverting the switch.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  funnelPorts = [
    443
    8443
    10000
  ];
  claims = config.dotfiles.tailscale.https;
  claimantsByPort = lib.groupBy (name: toString claims.${name}.port) (lib.attrNames claims);
in
{
  options.dotfiles.tailscale.waitForBackend = mkOption {
    type = types.path;
    readOnly = true;
    default = pkgs.writeShellScript "tailscale-wait-for-backend" ''
      until ${config.services.tailscale.package}/bin/tailscale status --json 2>/dev/null \
        | ${pkgs.jq}/bin/jq --exit-status '.BackendState == "Running"' >/dev/null; do
        sleep 1
      done
    '';
    description = "Script that waits until tailscaled is up and logged in, for a Serve unit's ExecStartPre; pair it with a TimeoutStartSec.";
  };

  options.dotfiles.tailscale.serve = mkOption {
    type = types.path;
    readOnly = true;
    default = pkgs.writeShellScript "tailscale-serve" ''
      set -euo pipefail

      tailscale="''${TAILSCALE_BIN:-${config.services.tailscale.package}/bin/tailscale}"
      lock="''${TAILSCALE_SERVE_LOCK:-/run/tailscale-serve-config.lock}"
      flock="${pkgs.util-linux}/bin/flock"
      grep="${pkgs.gnugrep}/bin/grep"
      max_attempts="''${TAILSCALE_SERVE_MAX_ATTEMPTS:-20}"
      retry_delay="''${TAILSCALE_SERVE_RETRY_DELAY:-0.25}"

      is_foreground=1
      for arg in "$@"; do
        case "$arg" in
          --bg | --bg=true | off | status | reset)
            is_foreground=0
            ;;
        esac
      done

      tmpdir="$(mktemp -d)"
      child=""
      drain=""
      flock_pid=""
      stopping=0

      cleanup() {
        if [ -n "$drain" ]; then
          kill "$drain" 2>/dev/null || true
          wait "$drain" 2>/dev/null || true
        fi
        rm -rf "$tmpdir"
      }
      trap cleanup EXIT

      forward_signal() {
        stopping=1
        if [ -n "$flock_pid" ]; then
          kill -TERM "$flock_pid" 2>/dev/null || true
        fi
        if [ -n "$child" ]; then
          kill -TERM "$child" 2>/dev/null || true
        fi
      }
      trap forward_signal TERM INT

      acquire_lock() {
        exec 9>"$lock"
        "$flock" 9 &
        flock_pid=$!
        wait "$flock_pid"
        flock_pid=""
      }

      release_lock() {
        "$flock" -u 9 2>/dev/null || true
        exec 9>&- 2>/dev/null || true
      }

      if [ "$is_foreground" -eq 0 ]; then
        attempt=0
        while true; do
          attempt=$((attempt + 1))
          errfile="$tmpdir/err.$attempt"
          rc=0
          acquire_lock
          "$tailscale" "$@" 9>&- 2>"$errfile" || rc=$?
          release_lock
          cat "$errfile" >&2
          if [ "$rc" -eq 0 ]; then
            exit 0
          fi
          if [ "$stopping" -eq 0 ] \
            && [ "$attempt" -lt "$max_attempts" ] \
            && "$grep" -qiE 'etag mismatch|another client is changing the serve config' "$errfile"; then
            sleep "$retry_delay"
            continue
          fi
          exit "$rc"
        done
      fi

      attempt=0
      while true; do
        attempt=$((attempt + 1))
        fifo="$tmpdir/out.$attempt"
        mkfifo "$fifo"

        acquire_lock

        "$tailscale" "$@" 9>&- >"$fifo" 2>&1 &
        child=$!

        exec 3<"$fifo"
        ready=0
        etag_err=0
        line=""
        while IFS= read -r -t 5 line <&3 || [ -n "$line" ]; do
          printf '%s\n' "$line"
          case "$line" in
            *"Available within your tailnet:"* | *"Available on the internet:"*)
              ready=1
              break
              ;;
            *"etag mismatch"* | *"Another client is changing the serve config"* | *"another client is changing the serve config"*)
              etag_err=1
              ;;
          esac
          line=""
        done

        # Release the lock once registration succeeds, the readiness timeout
        # passes, or the child exits, so long-lived foreground units never
        # block other Serve/Funnel units.
        release_lock

        if [ "$ready" -eq 1 ] || kill -0 "$child" 2>/dev/null; then
          cat <&3 &
          drain=$!
          exec 3<&-
          rc=0
          while true; do
            wait "$child" || rc=$?
            if kill -0 "$child" 2>/dev/null; then
              rc=0
              continue
            fi
            break
          done
          wait "$drain" 2>/dev/null || true
          drain=""
          exit "$rc"
        fi

        exec 3<&-
        rc=0
        wait "$child" || rc=$?
        child=""

        if [ "$stopping" -eq 0 ] \
          && [ "$rc" -ne 0 ] \
          && [ "$etag_err" -eq 1 ] \
          && [ "$attempt" -lt "$max_attempts" ]; then
          sleep "$retry_delay"
          continue
        fi
        exit "$rc"
      done
    '';
    description = "Wrapper around `tailscale serve` and `tailscale funnel` that serializes serve-config updates with flock and retries on etag mismatch.";
  };

  options.dotfiles.tailscale.https = mkOption {
    type = types.attrsOf (
      types.submodule {
        options = {
          port = mkOption {
            type = types.port;
            description = "HTTPS port on this host's tailnet name.";
          };
          funnel = mkOption {
            type = types.bool;
            default = false;
            description = "Whether Funnel publishes the port to the internet rather than only to the tailnet.";
          };
        };
      }
    );
    default = { };
    description = "HTTPS ports published through Tailscale Serve or Funnel, by the service that claims each.";
  };

  config.assertions =
    lib.mapAttrsToList (port: names: {
      assertion = lib.length names == 1;
      message = "Tailscale HTTPS port ${port} is claimed by ${lib.concatStringsSep " and " names}; Serve and Funnel share one port space per node.";
    }) claimantsByPort
    ++ lib.mapAttrsToList (name: claim: {
      assertion = !claim.funnel || lib.elem claim.port funnelPorts;
      message = "dotfiles.tailscale.https.${name}: Funnel publishes only ports 443, 8443 and 10000, not ${toString claim.port}.";
    }) claims;
}
