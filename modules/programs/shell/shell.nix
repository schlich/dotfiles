{
  config,
  inputs,
  lib,
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

  direnv = wrapWithConfig {
    package = pkgs.direnv;
    env.DIRENV_CONFIG = "${pkgs.linkFarm "direnv-config" [
      {
        name = "direnv.toml";
        path = toml.generate "direnv.toml" { global.hide_env_diff = true; };
      }
      {
        name = "lib/nix-direnv.sh";
        path = "${pkgs.nix-direnv}/share/nix-direnv/direnvrc";
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
    # wrapper's DIRENV_CONFIG directory carries direnv.toml and nix-direnv.
    programs.direnv = {
      enable = true;
      package = direnv;
      enableNushellIntegration = true;
      nix-direnv.enable = false;
    };

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
