{ config, pkgs, ... }:

{
  home.stateVersion = "25.05";
  home.username = "nixos";
  home.homeDirectory = /home/nixos;

  home.packages = with pkgs; [
    dust
    cargo-binstall
    gcc
    diffedit3
    bash
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
    rustup
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
    monaspace
    (pkgs.writeShellScriptBin "gemini" ''
      exec ${pkgs.bun}/bin/bunx @google/gemini-cli@preview "$@"
    '')
  ];

  home.file = {
    ".config/helix/config.toml".source = ./helix/config.toml;
    ".config/helix/languages.toml".source = ./helix/languages.toml;
  };
  home.sessionVariables = {
    NIXPKGS_ALLOW_UNFREE = 1;
  };

  home.sessionPath = [
    "$HOME/.nix-profile/bin"
    "/etc/profiles/per-user/$USER/bin"
  ];

  home.keyboard = {
    layout = "us,gr";
    options = [
      "grp:switch"
    ];
  };

  programs = {
    lazygit = {
      enable = true;
      enableNushellIntegration = true;
      settings = {
        os.editPreset = "helix";
      };
    };
    # gemini-cli = {
    #   enable = true;
    # };
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
    yazi = {
      enable = true;
      enableNushellIntegration = true;
      shellWrapperName = "y";
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
      configFile.source = ./nushell/config.nu;
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
        simple-completion-language-server
      ];
      defaultEditor = true;
    };
    bat.enable = true;
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
