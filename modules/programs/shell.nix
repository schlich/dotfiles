{ pkgs, ... }:

{
  programs.atuin = {
    enable = true;
    enableNushellIntegration = true;
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
    envFile.source = ../../env.nu;
    configFile.source = ../../config.nu;
  };

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      format = "$\{custom.jj}\$all";
      gcloud.disabled = true;
      git_branch.disabled = true;
      git_commit.disabled = true;
      custom.jj = {
        command = "prompt";
        format = "$output ";
        ignore_timeout = true;
        shell = [
          "${pkgs.starship-jj}/bin/starship-jj"
          "--ignore-working-copy"
          "starship"
        ];
        use_stdin = false;
        when = true;
      };
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

  programs.antigravity-cli.enable = true;
  programs.intelli-shell.settings.ai.enabled = true;
}
