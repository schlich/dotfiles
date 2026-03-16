{ config, pkgs, ... }:

{
  home = {
    stateVersion = "26.05";
    username = "schlich";
    homeDirectory = "/home/schlich";
    packages = with pkgs; [
      ripgrep
      devenv
      dust
      cargo-binstall
      diffedit3
      gh
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
      (pkgs.writeShellScriptBin "xdg-open" ''
        /mnt/c/Windows/System32/cmd.exe /c start "" "$1" >/dev/null 2>&1
        exit 0
      '')
    ];
    sessionVariables = {
      EDITOR = "hx";
      VISUAL = "hx";
    };
  };

  programs = {
    lazygit = {
      enable = true;
      enableNushellIntegration = true;
      settings = {
        os.editPreset = "helix";
      };
    };
    git = {
      enable = true;
      # extraConfig = {
      #   credential."https://github.com".helper = "!gh auth git-credential";
      #   credential."https://gist.github.com".helper = "!gh auth git-credential";
      # };
    };
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
        COLORTERM = "truecolor";
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
    wezterm.enable = true;
    helix = {
      enable = true;
      extraPackages = with pkgs; [
        nixd
        nixfmt
        marksman
      ];
      defaultEditor = true;
      settings = {
        theme = "base16_transparent";
        editor = {
          shell = [ "nu" ];
          line-number = "relative";
          completion-replace = true;
          completion-trigger-len = 0;
          completion-timeout = 5;
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
  xdg.portal = {
    enable = true;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.gtk.default = [ "gtk" ];
    xdgOpenUsePortal = true;
  };

}
