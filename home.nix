{ config, pkgs, ... }:

{
  home.stateVersion = "25.05";
  home.username = "schlich";
  home.homeDirectory = "/home/schlich";
  home.packages = with pkgs; [
    stow
    ripgrep
    devenv
    dust
    cargo-binstall
    diffedit3
    bash
    gh
    xdg-utils
    wslu
    systemctl-tui
    eget
    difftastic
    manix
    taplo
    rustup
    fx
    fzf
    bun
    uv
    opencode
    nerd-fonts.monaspace
    (pkgs.writeShellScriptBin "gemini" ''
      exec ${pkgs.bun}/bin/bunx @google/gemini-cli@preview "$@"
    '')
  ];


  home.sessionVariables = {
    NIXPKGS_ALLOW_UNFREE = 1;
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
    htop.enable = true;
    home-manager = {
      enable = true;
    };
    ghostty = {
      enable = true;
      installBatSyntax = true;
      settings = {
        initial-command = "nu";
      };
    };
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
        COLORTERM = "truecolor";
      };
      configFile.source = ./nushell/config.nu;
      extraConfig = ''
        source ${config.xdg.configHome}/yazelix/nushell/config/config.nu
      '';
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
      settings = {
        user = {
          name = "schlich";
          email = "ty.schlich@gmail.com";
        };
      };
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
      settings = {
        theme = "base16_transparent";
        editor = {
          shell = [ "nu" ];
          line-number = "relative";
          completion-replace = true;
          bufferline = "multiple";
          color-modes = true;
          trim-final-newlines = true;
          trim-trailing-whitespace = true;
          lsp = {
            display-inlay-hints = true;
          };
          cursor-shape = {
            insert = "bar";
          };
          soft-wrap = {
            enable = true;
          };
        };
      };
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
              command = "nixfmt";
              args = [
                "-"
              ];
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
    fd.enable = true;
  };

  services = {
    home-manager.autoUpgrade.useFlake = true;
    gpg-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
  };
}
