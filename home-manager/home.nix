{ config, pkgs, ... }:

{
  home.stateVersion = "25.05";

  home.packages = with pkgs; [
    gh
    allure
    biome
    xdg-utils
    wslu
    systemctl-tui
    nil
    nixd
    nix-search-tv
    eget
    difftastic
    chezmoi
    manix
    taplo
    cargo
    rustc
    fx
    nix-search-tv
    fzf
    rerun
    blender
    deno
    firefox
    libgcc
    bun
    d2
    nodejs
    uv
    opencode
    nixfmt
  ];

  home.file = {
    ".config/helix/config.toml".source = ./xdg/helix/config.toml;
    ".config/helix/languages.toml".source = ./xdg/helix/languages.toml;
  };
  home.sessionVariables = {
    NIXPKGS_ALLOW_UNFREE = 1;
  };

  home.sessionPath = [
    "$HOME/.nix-profile/bin"
    "/etc/profiles/per-user/$USER/bin"
  ];

  programs = {
    git.enable = true;
    starship = {
      enable = true;
      enableNushellIntegration = true;
      settings = {
        gcloud = {
          disabled = true;
        };
        git_branch = {
          disabled = true;
        };
        git_commit = {
          disabled = true;
        };
      };
    };
    nix-search-tv = {
      enable = true;
      enableTelevisionIntegration = true;
    };
    codex.enable = true;
    htop.enable = true;
    home-manager.enable = true;
    ghostty.enable = true;
    gemini-cli.enable = true;
    yazi = {
      enable = true;
      enableNushellIntegration = true;
    };
    direnv = {
      enable = true;
      enableNushellIntegration = true;
      nix-direnv.enable = true;
    };
    nushell = {
      enable = true;
      environmentVariables = {
        EDITOR = "${pkgs.helix}/bin/hx";
      };
      configFile.source = ./xdg/nushell/config.nu;
    };
    zoxide = {
      enable = true;
      enableNushellIntegration = true;
    };
    carapace = {
      enable = true;
      enableNushellIntegration = true;
    };
    jujutsu = {
      enable = true;
    };
    jjui.enable = true;
    atuin = {
      enable = true;
      enableNushellIntegration = true;
    };
    helix = {
      enable = true;
      extraPackages = with pkgs; [
        nixd
        nil
        nixfmt
        marksman
      ];
      defaultEditor = true;
    };
    zed-editor.enable = true;
  };

  services = {
    home-manager.autoUpgrade.useFlake = true;
    gpg-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
    ssh-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
  };
}
