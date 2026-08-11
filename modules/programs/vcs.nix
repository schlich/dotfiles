{
  config,
  lib,
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
    settings.os.editPreset = "helix";
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
      name = "jj-trunk";
      script = builtins.readFile ../../jj/trunk.nu;
    })
  ];

  # home.activation.installPrek = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
  #   repo=${config.home.homeDirectory}/dotfiles
  #   if [ -f "$repo/prek.toml" ] && [ -d "$repo/.git" ]; then
  #     ${pkgs.prek}/bin/prek -C "$repo" install -f
  #   fi
  # '';
}
