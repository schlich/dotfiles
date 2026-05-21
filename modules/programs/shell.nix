{ ... }:

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
  };

  programs.intelli-shell = {
    enable = true;
    enableNushellIntegration = true;
  };

  programs.nushell = {
    enable = true;
    configFile.source = ../../config.nu;
  };

  programs.starship = {
    enable = true;
    enableNushellIntegration = true;
    settings = {
      git_branch.disabled = true;
      git_commit.disabled = true;
      git_state.disabled = true;
      git_status.disabled = true;
      git_metrics.disabled = true;
      custom.jj = {
        description = "Current jj change";
        when = "jj root";
        command = ''jj log -r @ --no-graph --ignore-working-copy --color always -T '"(" ++ change_id.shortest(8) ++ ")" ++ if(empty, " (empty)", "") ++ if(conflict, " (conflict)", "") ++ if(bookmarks, " " ++ bookmarks.map(|b| b.name()).join(","), "") ++ if(description, " " ++ description.first_line(), "")' '';
        symbol = "jj ";
        format = "[$symbol$output]($style) ";
        style = "bold purple";
      };
    };
  };

  programs.yazi = {
    enable = true;
    enableNushellIntegration = true;
    shellWrapperName = "y";
  };

  programs.zellij.enable = true;

  programs.zoxide = {
    enable = true;
    enableNushellIntegration = true;
  };
}
