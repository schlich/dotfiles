{ pkgs, inputs, ... }:

{
  home = {
    stateVersion = "26.05";
    username = "schlich";
    homeDirectory = /home/schlich;
    packages = with pkgs; [
      rustup
      gcc
      ripgrep
      devenv
      dust
      diffedit3
      gh
      gh-dash
      systemctl-tui
      difftastic
      taplo
      fx
      fzf
      bun
      uv
      monaspace
      nerd-font-patcher
      nom
      lazyjj
      cargo-nextest
      pandoc
      inputs.rust-docs-mcp.packages.x86_64-linux.default
      # (pkgs.writeShellScriptBin "xdg-open" ''
      #   ${pkgs.coreutils}/bin/timeout 10s \
      #     /mnt/c/Windows/System32/cmd.exe /c start "" "$1" >/dev/null
      # '')
    ];
    sessionVariables = {
      EDITOR = "hx";
      VISUAL = "hx";
      RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
      SHELL = "nu";
    };
  };
  fonts.fontconfig.enable = true;

  programs = {
    zellij = {
      enable = true;
    };
    mcp = {
      enable = true;
      servers = {
        nixos = {
          command = "uvx";
          args = [ "mcp-nixos" ];
        };
        github = {
          url = "https://api.githubcopilot.com/mcp/insiders";
          oauth = false;
          headers = {
            Authorization = "Bearer {env:GITHUB_TOKEN}";
          };
        };
        nushell = {
          command = "nu";
          args = [ "--mcp" ];
        };
        rust-docs = {
          command = "rust-docs-mcp";
        };
      };
    };
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
        format = "$\{custom.jj}\$all";
        gcloud.disabled = true;
        git_branch.disabled = true;
        git_commit.disabled = true;
        custom.jj = {
          command = "prompt";
          format = "\$output";
          ignore_timeout = true;
          shell = [
            "starship-jj"
            "--ignore-working-copy"
            "starship"
          ];
          use_stdin = false;
          when = true;
        };
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
      config.global.hide_env_diff = true;
    };
    nushell = {
      enable = true;
      environmentVariables = {
        COLORTERM = "truecolor";
        EDITOR = "hx";
        VISUAL = "hx";
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
        nil
        nixfmt
        marksman
        rust-analyzer
      ];
      defaultEditor = true;
      settings = {
        theme = "base16_transparent";
        editor = {
          shell = [
            "nu"
            "-c"
          ];
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
          end-of-line-diagnostics = "hint";
          inline-diagnostics.cursor-line = "warning";

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
            config.nixd = {
              nixpkgs.expr = "import (builtins.getFlake (builtins.toString ./.)).inputs.nixpkgs { }";
              options = {
                nixos.expr = "(builtins.getFlake (builtins.toString ./.)).nixosConfigurations.nixos.options";
                home-manager.expr = "(builtins.getFlake (builtins.toString ./.)).homeConfigurations.schlich.options";
              };
            };
          };
        };
        language = [
          {
            name = "rust";
            auto-format = true;
            formatter = {
              command = "rustup";
              args = [ "-" ];
            };
          }
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
            language-servers = [
              "nil"
              "nixd"
            ];
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
    opencode = {
      enable = true;
      enableMcpIntegration = true;
      rules = ''
        Use Nushell for shell commands and jujutsu (jj) for version control.
        Use the appropriate skills.
      '';
      skills = {
        jj = ./copilot/skills/jj;
        nu = ./copilot/skills/nushell;
      };
      agents = ./copilot/agents;
      settings = {
        server.hostname = "localhost";
        mcp = {
          nixos = {
            command = [
              "uvx"
              "mcp-nixos"
            ];
            enabled = true;
            type = "local";
          };
        };
      };
    };
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
