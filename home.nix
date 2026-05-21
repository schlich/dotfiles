{ pkgs, inputs, ... }:

{
  imports = [ ./noctalia.nix ];

  home = {
    username = "schlich";
    homeDirectory = /home/schlich;
    stateVersion = "26.05";
    packages = with pkgs; [
      wget
      mesa-demos
      niri
      dhall
      skills
      ssh-to-age
      aider-chat
      aichat
      gcr
      clipboard-jh
      diffedit3
      difftastic
      dust
      eget
      font-awesome
      fx
      fzf
      gcc
      github-copilot-cli
      ghostty
      glow
      jjui
      lazyjj
      lsp-ai
      monaspace
      nerd-font-patcher
      nerd-fonts.symbols-only
      pavucontrol
      pandoc
      pixi
      rerun
      ripgrep
      rustup
      systemctl-tui
      systemd-manager-tui
      taplo
      uv
      wl-clipboard-rs
      zed-editor
      inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
      inputs.rust-docs-mcp.packages.${pkgs.stdenv.hostPlatform.system}.default
    ];
    sessionVariables = {
      EDITOR = "hx";
      VISUAL = "hx";
      RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
      SHELL = "nu";
    };
  };

  nixpkgs.config.allowUnfree = true;
  fonts.fontconfig.enable = true;
  xdg.configFile."helix/llm.nu".source = ./helix/llm.nu;
  xdg.configFile."helix/llm-tools.yaml".source = ./helix/llm-tools.yaml;
  xdg.configFile."niri/config.kdl".source = ./niri/config.kdl;
  programs = {
    claude-code = {
      enable = true;
      enableMcpIntegration = true;
      marketplaces.marimo-pair = inputs.marimo-pair;
      plugins = [ inputs.marimo-pair ];
      settings = {
        enabledPlugins."marimo-pair@marimo-pair" = true;
        hooks.PreToolUse = [
          {
            matcher = "Bash";
            hooks = [
              {
                type = "command";
                command = ''echo "Bash is disabled here. Use the nu MCP server instead: mcp__plugin_claude-code-home-manager_nu__evaluate for running commands, mcp__plugin_claude-code-home-manager_nu__list_commands to discover, mcp__plugin_claude-code-home-manager_nu__command_help for help. Rewrite the bash invocation as a nushell pipeline and call evaluate." >&2; exit 2'';
              }
            ];
          }
        ];
      };
    };
    codex = {
      enable = true;
      enableMcpIntegration = true;
    };
    nom = {
      enable = true;
      settings = {
        feeds = [
          {
            name = "adam-nyberg";
            url = "https://adamnyberg.se/rss.xml";
          }
          {
            name = "automerge";
            url = "https://automerge.org/index.xml";
          }
          {
            name = "ink-and-switch";
            url = "https://www.inkandswitch.com/index.xml";
          }
          {
            name = "lea-verou-phd";
            url = "https://lea.verou.me/feed.xml";
          }
          {
            name = "hacker-news";
            url = "https://news.ycombinator.com/rss";
          }
          {
            name = "nix-ci";
            url = "https://blog.nix-ci.com/rss.xml";
          }
        ];
      };
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
        # chrome-devtools = {
        #   command = "bunx";
        #   args = [ "chrome-devtools-mcp@latest" ];
        # };
        # playwright = {
        #   command = "bunx";
        #   args = [ "@playwright/mcp@latest" ];
        # };
        rust-docs = {
          command = "rust-docs-mcp";
        };
      };
    };

    opencode = {
      enable = true;
      enableMcpIntegration = true;
      context = ''
        Use Nushell for shell commands and jujutsu (jj) for version control.
        Use the appropriate skills.
      '';
      skills = {
        jj = ./copilot/skills/jj;
        marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
        nu = ./copilot/skills/nushell;
      };
      agents = ./copilot/agents;
      settings = {
        server.hostname = "localhost";
        tools.bash = false;
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

    helix = {
      enable = true;
      extraPackages = with pkgs; [
        nixd
        nil
        nixfmt
        marksman
        rust-analyzer
        taplo
        dhall
      ];
      defaultEditor = true;
      settings = {
        theme = "dark-synthwave";
        editor = {
          shell = [
            "nu"
            "-c"
          ];
          auto-save = {
            focus-lost = true;
          };
          line-number = "relative";
          completion-replace = true;
          completion-trigger-len = 0;
          completion-timeout = 5;
          bufferline = "multiple";
          color-modes = true;
          trim-final-newlines = true;
          trim-trailing-whitespace = true;
          lsp.display-inlay-hints = true;
          cursor-shape.insert = "bar";
          soft-wrap.enable = true;
          end-of-line-diagnostics = "hint";
          inline-diagnostics.cursor-line = "warning";
        };
        keys = {
          normal = {
            tab = "move_parent_node_end";
            S-tab = "move_parent_node_start";
            space = {
              a = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu
                }
              '';
              g = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu --tool gemini
                }
              '';
              c = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu --tool claude
                }
              '';
              x = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu --tool codex
                }
              '';
              p = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu --tool copilot
                }
              '';
              i = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu --tool aichat
                }
              '';
              o = ''
                :append-output #
                let prompt = r######'%{selection}'######
                if ($prompt | str trim | is-empty) {
                  print "hx-llm: select text before invoking the assistant"
                } else {
                  $prompt
                  | nu ~/.config/helix/llm.nu --tool opencode
                }
              '';
            };
          };
          insert = {
            S-tab = "move_parent_node_end";
          };
          select = {
            tab = "extend_parent_node_end";
            S-tab = "extend_parent_node_start";
          };
        };
      };
      languages = {
        language-server = {
          rust-analyzer.config.cargo.features = "all";
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
              command = "rustfmt";
              args = [ "-" ];
            };
          }
          {
            name = "python";
            language-servers = [ "ruff" ];
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
              args = [ "-" ];
            };
          }
          {
            name = "nu";
            auto-format = true;
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

    nushell = {
      enable = true;
      environmentVariables = {
        COLORTERM = "truecolor";
        EDITOR = "hx";
        VISUAL = "hx";
      };
      configFile.source = ./config.nu;
    };

    git = {
      enable = true;
      settings = {
        user.name = "schlich";
        user.email = "ty.schlich@gmail.com";
      };
    };

    gpg.enable = true;
    lazygit = {
      enable = true;
      enableNushellIntegration = true;
      settings.os.editPreset = "helix";
    };
    jujutsu = {
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
      };
    };

    atuin = {
      enable = true;
      enableNushellIntegration = true;
    };
    bat.enable = true;
    carapace = {
      enable = true;
      enableNushellIntegration = true;
    };
    direnv = {
      enable = true;
      enableNushellIntegration = true;
      nix-direnv.enable = true;
      config.global.hide_env_diff = true;
    };
    fd.enable = true;
    gemini-cli.enable = true;
    gh.enable = true;
    gh-dash.enable = true;
    ghostty = {
      enable = true;
      installBatSyntax = true;
    };
    htop.enable = true;
    home-manager.enable = true;
    intelli-shell = {
      enable = true;
      enableNushellIntegration = true;
      settings.ai.enabled = true;
    };
    jjui.enable = true;
    kitty = {
      enable = true;
      enableGitIntegration = true;
      font.name = "Monaspace Krypton";
    };
    navi.enable = true;
    nix-search-tv = {
      enable = true;
      enableTelevisionIntegration = true;
    };
    password-store = {
      enable = true;
      settings = { };
    };
    pet.enable = true;
    tealdeer = {
      enable = true;
      settings.updates.auto_update = true;
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
    wlogout.enable = true;
    yazi = {
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
    zed-editor.enable = true;
    zellij.enable = true;
    zoxide = {
      enable = true;
      enableNushellIntegration = true;
    };
    bun.enable = true;
  };

  services = {
    home-manager.autoUpgrade.useFlake = true;
    gpg-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
  };

}
