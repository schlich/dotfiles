{ pkgs, ... }:

{
  programs.helix = {
    enable = true;
    extraPackages = with pkgs; [
      nixd
      nil
      nixfmt
      marksman
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
        auto-save.focus-lost = true;
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
        };
        insert.S-tab = "move_parent_node_end";
        select = {
          tab = "extend_parent_node_end";
          S-tab = "extend_parent_node_start";
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
            schemas."https://json.schemastore.org/github-workflow.json" = ".github/workflows/*.{yml,yaml}";
          };
        };
        nixd = {
          command = "nixd";
          config.nixd = {
            nixpkgs.expr = "import (builtins.getFlake (builtins.toString ./.)).inputs.nixpkgs { }";
            options = {
              nixos.expr = "(builtins.getFlake (builtins.toString ./.)).nixosConfigurations.asus.options";
              home-manager.expr = "(builtins.getFlake (builtins.toString ./.)).homeConfigurations.schlich.options";
            };
          };
        };
      };
      language = [
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
            command = "nix";
            args = [
              "fmt"
              "-"
            ];
          };
        }
        {
          name = "nu";
          auto-format = true;
        }
        { name = "yaml"; }
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

  programs.zed-editor.enable = true;
}
