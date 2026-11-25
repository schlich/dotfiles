{
  config,
  inputs,
  lib,
  osConfig ? { },
  pkgs,
  ...
}:

let
  cfg = config.dotfiles.shell.hostBadge;
  wrapWithConfig = import ../../../lib/wrap-with-config.nix { inherit lib pkgs; };
  toml = pkgs.formats.toml { };

  atuinPackage = pkgs.atuin;
  atuin = wrapWithConfig {
    package = atuinPackage;
    # The daemon that `autostart` launches inherits the variable.
    env.ATUIN_CONFIG_DIR = "${pkgs.linkFarm "atuin-config" [
      {
        name = "config.toml";
        path = toml.generate "atuin-config.toml" {
          daemon = {
            enabled = true;
            autostart = true;
          };
          # Atuin's built-in secrets_filter covers AWS, GCP, GitHub, Slack and
          # npm, but not OpenAI or Gemini, so inline credential assignments are
          # otherwise stored verbatim in the history database. Run
          # `atuin history prune` after changing this to drop existing matches.
          history_filter = [
            ''\$env\.[A-Z0-9_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*=''
          ];
        };
      }
    ]}";
  };

  # The host's real Nix binary: on workstations `nix` on PATH is iets's
  # classic-mode front, which falls back on nix-direnv's `--no-warn-dirty`.
  realNix = lib.getExe' (osConfig.iets.classic.nix or osConfig.nix.package or pkgs.nix) "nix";

  # Loaded after nix-direnv so `use flake` runs through `iets print-dev-env`
  # for local locked flakes and falls back to nix-direnv for flags, remote or
  # unlocked flakes, manual reload, or features iets lacks (exit 2/3). When
  # nix-direnv runs (fallback or `use nix`), call the real Nix directly so
  # iets never prints its `--no-warn-dirty` fallback warning.
  ietsDirenvLib = pkgs.writeText "iets-direnv.sh" ''
    _direnv_nix_direnv_use_flake_def="$(declare -f use_flake)"
    eval "_nix_direnv_use_flake''${_direnv_nix_direnv_use_flake_def#use_flake}"
    unset _direnv_nix_direnv_use_flake_def

    _nix() {
      "''${NIX_DIRENV_REAL_NIX:-${realNix}}" --no-warn-dirty --extra-experimental-features "nix-command flakes" "$@"
    }

    use_flake() {
      local ref="''${1:-.}" uri layout_dir root entry rc script status
      local -a paths

      if ! has iets || [[ ''${_nix_direnv_manual_reload:-0} == 1 ]] || [[ $# -gt 1 || $ref == -* ]]; then
        _nix_direnv_use_flake "$@"
        return
      fi

      uri="''${ref%#*}"
      uri="''${uri#path:}"
      if [[ -z $uri || ! -f $uri/flake.lock ]]; then
        _nix_direnv_use_flake "$@"
        return
      fi

      layout_dir="$(direnv_layout_dir)"
      root="$layout_dir/iets-env"
      entry="$layout_dir/iets-entry"
      rc="$layout_dir/iets-env.rc"
      mkdir -p "$layout_dir"

      status=0
      script="$(iets print-dev-env --builder daemon --gc-root "$root" --entry-to "$entry" "$ref")" || status=$?

      if [[ $status -eq 2 || $status -eq 3 ]]; then
        log_status "iets: falling back to nix-direnv for '$ref'"
        _nix_direnv_use_flake "$@"
        return
      fi

      watch_file "$uri/flake.nix" "$uri/flake.lock"
      if [[ -s $entry && -e $(<"$entry") ]]; then
        mapfile -d "" -t paths < <(iets cache paths "$(<"$entry")" 2>/dev/null)
        if ((''${#paths[@]} > 0)); then
          watch_file "''${paths[@]}"
        fi
      fi

      if [[ $status -ne 0 ]]; then
        return "$status"
      fi

      printf '%s\n' "$script" > "$rc"
      _nix_import_env "$rc"
    }
  '';

  direnv = wrapWithConfig {
    package = pkgs.direnv;
    env.DIRENV_CONFIG = "${pkgs.linkFarm "direnv-config" [
      {
        name = "direnv.toml";
        path = toml.generate "direnv.toml" { global.hide_env_diff = true; };
      }
      {
        name = "lib/00-nix-direnv.sh";
        path = "${pkgs.nix-direnv}/share/nix-direnv/direnvrc";
      }
      {
        name = "lib/10-iets-direnv.sh";
        path = ietsDirenvLib;
      }
    ]}";
  };

  # `starship init nu` embeds the path of the binary it runs as, which for a
  # wrapper is the unwrapped program, so the prompt would skip a wrapper's
  # variables; config.nu sets STARSHIP_CONFIG instead.
  #
  # Starship runs `when` as well as `command` through `shell`, so with
  # `use_stdin = false` each is the shell's last argument: `jj-starship
  # detect` and `jj-starship prompt`. Fed on stdin instead, `when` ran the
  # whole prompt a second time and pushed it past `command_timeout`.
  # The running system's generation, for the prompt: the system profile's
  # link that points at /run/current-system, the newest when several do, and
  # the boot default's when it differs, as `generation --line` shows it
  # (deploy/generation.nu). Two forks instead of starting Nushell; it prints
  # nothing off NixOS.
  promptGeneration = pkgs.writeShellScript "prompt-generation" ''
    running=$(${pkgs.coreutils}/bin/readlink /run/current-system 2>/dev/null) || exit 0
    links=$(${pkgs.findutils}/bin/find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' -printf '%f %l\n')
    generation=""
    boot=""
    default=$(${pkgs.coreutils}/bin/readlink /nix/var/nix/profiles/system)
    while read -r name target; do
      n=''${name#system-}
      n=''${n%-link}
      if [ "$target" = "$running" ] && [ "''${n}" -gt "''${generation:-0}" ]; then generation=$n; fi
      if [ "$name" = "$default" ]; then boot=$n; fi
    done <<<"$links"
    [ -n "$generation" ] || exit 0
    if [ -n "$boot" ] && [ "$boot" != "$generation" ]; then
      printf 'gen %s boot %s' "$generation" "$boot"
    else
      printf 'gen %s' "$generation"
    fi
  '';

  starshipConfig = toml.generate "starship.toml" {
    # The host and its running system generation lead the prompt, on every
    # host and not only over ssh, so a session always shows which machine
    # it runs on; `$all` follows with every other module.
    format = "$hostname\${custom.generation}$all";
    hostname =
      if cfg.enable then
        {
          ssh_only = false;
          ssh_symbol = "";
          format = "[ $hostname ]($style) ";
          style = cfg.style;
        }
      else
        {
          ssh_only = false;
          format = "[$hostname]($style) ";
        };
    custom.generation = {
      shell = [ "${promptGeneration}" ];
      use_stdin = false;
      when = true;
      command = "prompt";
      style = "dimmed";
      format = "([$output]($style) )";
    };
    custom.jj = {
      shell = [ "jj-starship" ];
      use_stdin = false;
      when = "detect";
      command = "prompt";
      format = "$output ";
    };
    # The topic's `ci` stage, pipeline verdict, and trunk drift, in a
    # repository that opted into ci: `ci-enabled` runs `context-status prompt`
    # there and prints nothing elsewhere, so it needs no `when`. It reads
    # only local state and a cache that it refreshes in the background.
    custom.context = {
      shell = [
        "ci-enabled"
        "context-status"
      ];
      use_stdin = false;
      when = true;
      command = "prompt";
      format = "($output )";
    };
    gcloud.disabled = true;
    git_branch.disabled = true;
    git_commit.disabled = true;
    git_status.disabled = true;
  };

  # Atuin binds Ctrl+R and Up only for the emacs and vi modes, and config.nu
  # runs Nushell in helix mode, where they never fired; add the helix modes,
  # and fail the build if Atuin's init stops matching.
  atuinNushellConfig = pkgs.runCommandLocal "atuin-nushell-config.nu" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${atuinPackage}/bin/atuin init nu \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_search/}' \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_up/}' \
      | ${pkgs.gnused}/bin/sed 's/mode: \[emacs, vi_normal, vi_insert\]/mode: [emacs, vi_normal, vi_insert, helix_normal, helix_insert]/' \
      > "$out"
    ${pkgs.gnugrep}/bin/grep -q 'helix_insert' "$out"
  '';
  atuinPtyProxyNushellConfig = pkgs.runCommandLocal "atuin-pty-proxy-nushell-config.nu" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${atuinPackage}/bin/atuin pty-proxy init nu > "$out"
  '';
in

{
  # dotfiles.nushellAutoload, which vcs.nix also sets.
  imports = [ ./nushell-autoload.nix ];

  options.dotfiles.shell.hostBadge = {
    enable = lib.mkEnableOption "a high-contrast hostname pill in the Starship prompt";
    style = lib.mkOption {
      type = lib.types.str;
      default = "bold black bg:yellow";
      description = "Starship style for the hostname pill when hostBadge is enabled.";
    };
  };

  config = {
    # config.nu sources Atuin's init scripts below, so Home Manager's atuin
    # module is not needed.
    home.packages = [ atuin ];

    # The hosts' overlay (modules/nixos/base/user/nushell-package.nix) carries a
    # Nushell newer than nixpkgs; this home builds from that package set.
    dotfiles.nixpkgsWatch.nushell = {
      inherit (pkgs.nushell) version;
      reason = "delete modules/nixos/base/user/nushell-package.nix and its imports in modules/nixos/base/user/default.nix and flake.nix";
    };

    programs.carapace = {
      enable = true;
      enableNushellIntegration = true;
    };

    # The module still adds the Nushell hook, which calls this package; the
    # wrapper's DIRENV_CONFIG directory carries direnv.toml, nix-direnv, and
    # the iets `use flake` wrapper with nix-direnv fallback.
    programs.direnv = {
      enable = true;
      package = direnv;
      enableNushellIntegration = true;
      nix-direnv.enable = false;
    };

    dotfiles.tooling.checks.direnv-iets-fallback =
      pkgs.runCommandLocal "direnv-iets-fallback-check"
        {
          nativeBuildInputs = [
            pkgs.bash
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.jq
            direnv
          ];
        }
        ''
          set -euo pipefail
          export HOME="$TMPDIR/home" XDG_DATA_HOME="$TMPDIR/data" XDG_CONFIG_HOME="$TMPDIR/config"
          mkdir -p "$HOME" "$TMPDIR/stubs"

          # Trap `nix` on PATH so any fallback that forgets to bypass it fails.
          cat > "$TMPDIR/stubs/nix" <<'EOF'
          #!${pkgs.bash}/bin/bash
          echo "unexpected PATH nix call: $*" >&2
          exit 99
          EOF
          chmod +x "$TMPDIR/stubs/nix"

          cat > "$TMPDIR/stubs/real-nix" <<'EOF'
          #!${pkgs.bash}/bin/bash
          shift 3
          case "$1" in
            print-dev-env)
              touch "$3"
              printf 'export FROM_NIX_DIRENV=1\n'
              ;;
            build)
              cp "$4" "$3"
              ;;
            flake)
              printf '{}\n'
              ;;
            *)
              echo "unexpected real-nix subcommand: $*" >&2
              exit 98
              ;;
          esac
          EOF
          chmod +x "$TMPDIR/stubs/real-nix"

          cat > "$TMPDIR/stubs/iets" <<'EOF'
          #!${pkgs.bash}/bin/bash
          if [[ $1 == cache && $2 == paths ]]; then
            printf 'extra.nix\0'
            exit 0
          fi
          if [[ $1 != print-dev-env ]]; then
            echo "unexpected iets call: $*" >&2
            exit 97
          fi
          mode="''${TEST_IETS_MODE:-ok}"
          if [[ $mode == fail-unsupported ]]; then
            exit 3
          elif [[ $mode == fail-eval ]]; then
            exit 1
          fi
          entry=""
          while [[ $# -gt 0 ]]; do
            if [[ $1 == --entry-to ]]; then
              entry="$2"
              shift 2
            else
              shift
            fi
          done
          entry_file="$TMPDIR/cache-entry"
          : > "$entry_file"
          printf '%s\n' "$entry_file" > "$entry"
          printf 'export FROM_IETS=1\nexport TMPDIR=/tmp/nix-shell.fake\n'
          EOF
          chmod +x "$TMPDIR/stubs/iets"

          export PATH="$TMPDIR/stubs:$PATH"
          export NIX_DIRENV_REAL_NIX="$TMPDIR/stubs/real-nix"

          # 1. Local locked flake uses iets, watches cached paths, and restores TMPDIR.
          mkdir -p "$TMPDIR/proj-iets"
          : > "$TMPDIR/proj-iets/flake.nix"
          : > "$TMPDIR/proj-iets/flake.lock"
          : > "$TMPDIR/proj-iets/extra.nix"
          printf 'use flake\n' > "$TMPDIR/proj-iets/.envrc"
          (cd "$TMPDIR/proj-iets" && direnv allow)
          env_json="$(cd "$TMPDIR/proj-iets" && direnv export json)"
          test "$(jq -r '.FROM_IETS // empty' <<<"$env_json")" = "1"
          test -z "$(jq -r '.FROM_NIX_DIRENV // empty' <<<"$env_json")"
          test "$(jq -r '.TMPDIR // empty' <<<"$env_json")" != "/tmp/nix-shell.fake"
          watches="$(jq -r '.DIRENV_WATCHES // empty' <<<"$env_json")"
          direnv show_dump "$watches" | grep -q 'extra\.nix'

          # 2. Extra flags bypass iets and fall back to nix-direnv via real-nix.
          mkdir -p "$TMPDIR/proj-flags"
          : > "$TMPDIR/proj-flags/flake.nix"
          : > "$TMPDIR/proj-flags/flake.lock"
          printf 'use flake . --impure\n' > "$TMPDIR/proj-flags/.envrc"
          (cd "$TMPDIR/proj-flags" && direnv allow)
          env_json="$(cd "$TMPDIR/proj-flags" && direnv export json)"
          test "$(jq -r '.FROM_NIX_DIRENV // empty' <<<"$env_json")" = "1"
          test -z "$(jq -r '.FROM_IETS // empty' <<<"$env_json")"

          # 3. Missing flake.lock falls back to nix-direnv via real-nix.
          mkdir -p "$TMPDIR/proj-unlocked"
          : > "$TMPDIR/proj-unlocked/flake.nix"
          printf 'use flake\n' > "$TMPDIR/proj-unlocked/.envrc"
          (cd "$TMPDIR/proj-unlocked" && direnv allow)
          env_json="$(cd "$TMPDIR/proj-unlocked" && direnv export json)"
          test "$(jq -r '.FROM_NIX_DIRENV // empty' <<<"$env_json")" = "1"
          test -z "$(jq -r '.FROM_IETS // empty' <<<"$env_json")"

          # 4. Unsupported iets feature (exit 3) falls back to nix-direnv via real-nix.
          mkdir -p "$TMPDIR/proj-unsupported"
          : > "$TMPDIR/proj-unsupported/flake.nix"
          : > "$TMPDIR/proj-unsupported/flake.lock"
          printf 'use flake\n' > "$TMPDIR/proj-unsupported/.envrc"
          (cd "$TMPDIR/proj-unsupported" && direnv allow)
          env_json="$(cd "$TMPDIR/proj-unsupported" && TEST_IETS_MODE=fail-unsupported direnv export json)"
          test "$(jq -r '.FROM_NIX_DIRENV // empty' <<<"$env_json")" = "1"
          test -z "$(jq -r '.FROM_IETS // empty' <<<"$env_json")"

          # 5. Real evaluation failure (exit 1) does not fall back to nix-direnv.
          mkdir -p "$TMPDIR/proj-eval-fail"
          : > "$TMPDIR/proj-eval-fail/flake.nix"
          : > "$TMPDIR/proj-eval-fail/flake.lock"
          printf 'use flake\n' > "$TMPDIR/proj-eval-fail/.envrc"
          (cd "$TMPDIR/proj-eval-fail" && direnv allow)
          env_json="$(cd "$TMPDIR/proj-eval-fail" && TEST_IETS_MODE=fail-eval direnv export json 2>/dev/null || true)"
          test -z "$(jq -r '.FROM_NIX_DIRENV // empty' <<<"$env_json")"
          test -z "$(jq -r '.FROM_IETS // empty' <<<"$env_json")"

          touch "$out"
        '';

    programs.intelli-shell = {
      enable = true;
      enableNushellIntegration = true;
    };

    # config.nu stays a Home Manager link: Nushell has no variable that names
    # it, an explicit --config also loads for scripts and `nu -c`, and vendor
    # autoload reaches the agent MCP server too. See docs/architecture.md.
    programs.nushell = {
      enable = true;
      loadSessionVariables = true;
      environmentVariables = {
        COLORTERM = "truecolor";
        STARSHIP_CONFIG = "${starshipConfig}";
      };
      configFile.source = ../../../config.nu;
      extraConfig = lib.mkMerge [
        ''
          source ${atuinPtyProxyNushellConfig}
          source ${atuinNushellConfig}
          source ${../../../mcp/agent-shell.nu}
          use ${../../../mcp/rlm.nu} *
          source ${../../../mcp/terminal-events.nu}
          setup-terminal-events
          source ${../../../nushell/project.nu}
          source ${../../../nushell/context-status.nu}
          setup-context-status
        ''
        # Program Status Protocol (OSC 7501): `pst` reports status to the
        # terminal, and background jobs show as jobs/<id> records. The jobs
        # hook wraps PROMPT_COMMAND, so it must run after starship sets it.
        (lib.mkAfter ''
          use ${inputs.osc7501-nu}/pst
          pst jobs install
        '')
        # A project's .envrc.nu loads as the `envrc` overlay once direnv has
        # loaded the project. Its hooks wrap direnv's prompt hook, which the
        # direnv module adds with mkAfter (1500), so they install after it.
        (lib.mkOrder 1600 ''
          source ${../../../nushell/envrc-nu.nu}
          setup-envrc-nu
        '')
        # Rex (modules/tooling/terminals/rex.nix). nurx appends its hooks, so it
        # loads after every other hook setup. Only `status` (OSC 7501 per
        # command) and `tint` are on: the picker, `last`, and `layout` need a
        # Rex app to show anything, and Linux has none yet. Rex puts its own
        # `rex` first on PATH in each terminal, but the session's PATH setup
        # runs after it, so it goes back to the front here.
        (lib.mkOrder 1700 ''
          if ($env.REX_BIN_DIR? | is-not-empty) {
            $env.PATH = ($env.PATH | where $it != $env.REX_BIN_DIR | prepend $env.REX_BIN_DIR)
          }
          use ${inputs.nu-rex-integration}/nurx.nu *
          nurx enable status tint
        '')
      ];
    };

    dotfiles.nushellAutoload.xs = "${inputs.xs}/xs.nu";

    # Without settings the module links no starship.toml. Its session
    # variable would name ~/.config/starship.toml, so point it at the same
    # store file as config.nu.
    programs.starship = {
      enable = true;
      enableNushellIntegration = true;
    };
    home.sessionVariables.STARSHIP_CONFIG = lib.mkForce "${starshipConfig}";

    dotfiles.retiredHomeFiles = [
      ".config/atuin/config.toml"
      ".config/direnv/direnv.toml"
      ".config/direnv/lib/hm-nix-direnv.sh"
      ".config/starship.toml"
    ];

    programs.zoxide = {
      enable = true;
      enableNushellIntegration = true;
    };

    programs.intelli-shell.settings.ai = {
      enabled = true;
      catalog.main = {
        provider = "openai";
        model = "gpt-5.6-luna";
      };
    };
  };
}
