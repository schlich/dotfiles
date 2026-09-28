{ inputs, pkgs, ... }:

let
  atuinNushellConfig = pkgs.runCommandLocal "atuin-nushell-config.nu" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${pkgs.atuin}/bin/atuin init nu \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_search/}' \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_up/}' \
      > "$out"
  '';
  atuinPtyProxyNushellConfig = pkgs.runCommandLocal "atuin-pty-proxy-nushell-config.nu" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${pkgs.atuin}/bin/atuin pty-proxy init nu > "$out"
  '';
in

{
  programs.atuin = {
    enable = true;
    enableNushellIntegration = false;
    settings = {
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
  };

  programs.carapace = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.direnv = {
    enable = true;
    enableNushellIntegration = true;
    nix-direnv.enable = true;
    config.global.hide_env_diff = true;
  };

  programs.intelli-shell = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.nushell = {
    enable = true;
    environmentVariables = {
      COLORTERM = "truecolor";
    };
    configFile.source = ../../config.nu;
    extraConfig = ''
      source ${atuinPtyProxyNushellConfig}
      source ${atuinNushellConfig}
      source ${../../mcp/agent-shell.nu}
      use ${../../mcp/rlm.nu} *
      source ${../../mcp/terminal-events.nu}
      setup-terminal-events
      source ${../../nushell/project.nu}
    '';
  };

  xdg.configFile."nushell/autoload/xs.nu".source = "${inputs.xs}/xs.nu";

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      custom.jj = {
        when = "jj-starship detect";
        shell = [ "jj-starship" ];
        format = "$output ";
      };
      gcloud.disabled = true;
      git_branch.disabled = true;
      git_commit.disabled = true;
      git_status.disabled = true;
    };
  };

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
