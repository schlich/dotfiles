{
  pkgs,
  ...
}:

{
  programs.git = {
    enable = true;
    settings.user = {
      email = "ty.schlich@gmail.com";
      name = "Ty Schlichenmeyer";
    };
    settings.remote.pushDefault = "origin";
  };
  programs.gpg.enable = true;
  programs.lazygit = {
    enable = true;
    enableNushellIntegration = true;
  };
  programs.jjui.enable = true;

  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        email = "ty.schlich@gmail.com";
        name = "schlich";
      };
      ui.diff-formatter = [
        "difft"
        "--color=always"
        "$left"
        "$right"
      ];
      git.push = "origin";
      templates.git_push_bookmark = ''"trunk/" ++ change_id.short()'';
    };
  };

  home.packages = [
    (pkgs.nuenv.writeScriptBin {
      name = "jj-describe";
      script = builtins.readFile ../../jj/describe.nu;
    })
    (pkgs.nuenv.writeScriptBin {
      name = "jj-flake";
      script = builtins.readFile ../../jj/flake.nu;
    })
    (pkgs.nuenv.writeScriptBin {
      name = "jj-ci";
      script = builtins.readFile ../../jj/ci.nu;
    })
  ];
}
