{ config, pkgs, ... }:

{
  home.stateVersion = "25.05";
  home.username = "nixos";
  home.homeDirectory = "/home/nixos";
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
    ".config/helix/config.toml".source = ../helix/config.toml;
    ".config/niri/config.kdl".source = ../niri/config.kdl;
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
    git.enable = true;
    starship = {
      enable = true;
      enableNushellIntegration = true;
      settings = {
        gcloud.disabled = true;
        git_branch.disabled = true;
        git_commit.disabled = true;
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
      configFile.source = ../nushell/config.nu;
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
      languages = {
        language-server = {
          hx-lsp = {
            command = "hx-lsp";
          };
          ruff = {
            command = "ruff";
            args = [ "server" ];
          };
          yaml-language-server = {
            config.yaml = {
              validation = true;
              format.enable = true;
              schemas = {
                "https://json.schemastore.org/github-workflow.json" = ".github/workflows/*.{yml,yaml}";
              };
            };
          };
          nixd = {
            command = "nixd";
          };
        };
        language = [
          {
            name = "python";
            language-servers = [
              "ruff"
              "basedpyright"
              "hx-lsp"
            ];
            formatter = {
              command = "ruff";
              args = [
                "format"
                "-"
              ];
            };
            auto-format = true;
          }
          {
            name = "nix";
            language-servers = [ "nixd" ];
            auto-format = true;
            formatter = {
              command = "nix";
              args = [
                "fmt"
                "-"
              ];
            };
          }
          {
            name = "sql";
            formatter = {
              command = "sqlfmt";
              args = [ "-" ];
            };
          }
          {
            name = "yaml";
          }
          {
            name = "toml";
            language-servers = [ "taplo" ];
            formatter = {
              command = "taplo";
              args = [
                "format"
                "-"
              ];
            };
          }
        ];
      };
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
