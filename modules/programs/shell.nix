{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  wrapWithConfig = import ../../lib/wrap-with-config.nix { inherit lib pkgs; };
  toml = pkgs.formats.toml { };

  atuinPackage = import ./atuin-package.nix { inherit inputs pkgs; };
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
  starshipConfig = toml.generate "starship.toml" {
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

  atuinNushellConfig = pkgs.runCommandLocal "atuin-nushell-config.nu" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${atuinPackage}/bin/atuin init nu \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_search/}' \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_up/}' \
      > "$out"
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

  # config.nu sources Atuin's init scripts below, so Home Manager's atuin
  # module is not needed.
  home.packages = [ atuin ];

  dotfiles.nixpkgsWatch.atuin = {
    inherit (atuinPackage) version;
    reason = "use pkgs.atuin where modules/programs/atuin-package.nix is imported (shell.nix, tooling/ai/common.nix, tooling/editors/zed.nix), delete that file, and drop the atuin input";
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
    environmentVariables = {
      COLORTERM = "truecolor";
      STARSHIP_CONFIG = "${starshipConfig}";
    };
    configFile.source = ../../config.nu;
    extraConfig = lib.mkMerge [
      ''
        source ${atuinPtyProxyNushellConfig}
        source ${atuinNushellConfig}
        source ${../../mcp/agent-shell.nu}
        use ${../../mcp/rlm.nu} *
        source ${../../mcp/terminal-events.nu}
        setup-terminal-events
        source ${../../nushell/project.nu}
        source ${../../nushell/context-status.nu}
        setup-context-status
      ''
      # Program Status Protocol (OSC 7501): `pst` reports status to the
      # terminal, and background jobs show as jobs/<id> records. The jobs
      # hook wraps PROMPT_COMMAND, so it must run after starship sets it.
      (lib.mkAfter ''
        use ${inputs.osc7501-nu}/pst
        pst jobs install
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
}
