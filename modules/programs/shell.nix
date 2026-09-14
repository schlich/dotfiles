{ pkgs, ... }:

let
  atuinNushellConfig = pkgs.runCommandLocal "atuin-nushell-config.nu" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    ${pkgs.atuin}/bin/atuin init nu \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_search/}' \
      | ${pkgs.gnused}/bin/sed '0,/name: atuin$/{s/name: atuin$/name: atuin_up/}' \
      > "$out"
  '';
in

{
  programs.atuin = {
    enable = true;
    enableNushellIntegration = false;
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
    extraEnv = ''
      try {
        $env.GITHUB_TOKEN = (
          ^${pkgs.secretspec}/bin/secretspec get
            --file ${../secretspec.toml}
            --provider keyring
            GITHUB_TOKEN
          | str trim
        )
      }
    '';
    configFile.source = ../../config.nu;
    extraConfig = ''
      source ${atuinNushellConfig}
      source ${../../mcp/agent-shell.nu}
    '';
  };

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

  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
    shellWrapperName = "y";
    settings = {
      manager = {
        show_hidden = false;
        sort_by = "modified";
        sort_dir_first = true;
      };
      preview = {
        max_width = 1000;
        max_height = 1000;
      };
    };
  };

  programs.zellij.enable = true;

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
