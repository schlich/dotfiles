{ pkgs, lib, ... }:

{
  nixpkgs.config = {
    allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "terraform"
      "vault"
    ];
  };
  home.username = "tyschlichenmeyer";
  home.homeDirectory = "/Users/tyschlichenmeyer";
  home.preferXdgDirectories = true;

  home.stateVersion = "24.05";

  home.packages = with pkgs; [
    uv
    nil
    nixpkgs-fmt
    python313
    just
    fx
    terraform
    vault
    basedpyright
    nodejs
    nix-search-cli
    devenv
    yaml-language-server
    ansible-language-server
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
  ];

  home.file = {
    "/Users/tyschlichenmeyer/.config/zellij/config.kdl".source = ./zellij/config.kdl;
    "/Users/tyschlichenmeyer/.config/zellij/layouts/default.kdl".source = ./zellij/layouts/default.kdl;
    "/Users/tyschlichenmeyer/.local/share/dagster/dagster.yaml".source = ./dagster.yaml;
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/tyschlichenmeyer/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
  };

  xdg.enable = true;
  # Let Home Manager install and manage itself.
  programs = {
    home-manager.enable = true;
    nushell = {
      enable = true;
      envFile.source = ./nushell/env.nu;
      configFile.source = ./nushell/config.nu;
      environmentVariables = {
        EDITOR = "'hx'";
        SNOWFLAKE_USER = "'TSCHLIC'";
        SNOWFLAKE_PASSWORD = "^pass show snowflake";
        DECIPHER_API_KEY = "^pass show decipher";
        DAGSTER_HOME = "$env.HOME | path join .local share dagster";
        AWS_DEFAULT_PROFILE = "'tschlic'";
        VAULT_ADDR = "'http://127.0.0.1:8200'";
        ENABLE_SNOWFLAKE = "true";
      };
      shellAliases = {
        hme = "home-manager edit";
        hms = "home-manager switch";
        activate = "overlay use .venv/bin/activate.nu";
        lg = "lazygit";
        oco = "bunx opencommit";
      };
    };
    helix = {
      enable = true;
      defaultEditor = true;
      languages = {
        language = [
          {
            name = "python";
            language-servers = [
              "ruff"
              "basedpyright"
            ];
            formatter = { command = "ruff"; args = ["format" "-"]; };
            auto-format = true;
          }
          {
            name = "nix";
            formatter = { command = "nixpkgs-fmt"; };
          }
          {
            name = "sql";
            formatter = { command = "sqlfmt"; args = ["-"]; };
          }
        ];
        language-server.ruff = {
          command = "ruff";
          args = ["server"];
        };
        language-server.nu = {
          command = "nu";
          args = ["--lsp"];
        };
        language-server.yaml-language-server.config.yaml = {
          format.enable = true;
          validation = true;
          schemas = {
            "https://json.schemastore.org/github-workflow.json" = ".github/workflows/*.{yml,yaml}";
            "https://raw.githubusercontent.com/ansible-community/schemas/main/f/ansible-tasks.json" = "roles/{tasks,handlers}/*.{yml,yaml}";
          };
        };    
      };
    };

    bat.enable = true;
    starship = {
      enable = true;
      enableNushellIntegration = true;
    };
    zoxide = {
      enable = true;
      enableNushellIntegration = true;
    };
    lazygit = {
      enable = true;
      settings = {
        customCommands = [
          {
            key = "c";
            command = "uv run cz commit";
            description = "commit with commitizen";
            context = "files";
            loadingText = "opening commitizen commit tool";
            subprocess = true;
          }
        ];
      };
    };
    gh = {
      enable = true;
      extensions = [ pkgs.gh-dash ];
    };
    zellij.enable = true;
    ruff = {
      enable = true;
      settings = {};
    };
    password-store.enable = true;
    gpg.enable = true;
    yazi = {
      enable = true;
      enableNushellIntegration = true;
    };
    carapace = {
      enable = true;
      enableNushellIntegration = true;
    };
    java.enable = true;
    tealdeer.enable = true;
    git = {
      enable = true;
      delta.enable = true;
      ignores = [
        "__pycache__"
        ".envrc"
      ];
      extraConfig = {
        core.editor = "hx";
      };
    };
    bun = {
      enable = true;
      enableGitIntegration = true;
    };
  };
}
