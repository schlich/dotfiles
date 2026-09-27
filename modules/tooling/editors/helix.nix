{
  config,
  lib,
  pkgs,
  ...
}:

let
  zellij = lib.getExe config.programs.zellij.package;

  # Runs in a floating Zellij pane: Yazi's open action writes the chosen paths
  # and quits, and they are typed into the Helix pane as an :open command.
  yaziPick = pkgs.writeNuScriptBin "hx-yazi-pick" ''
    def main [helix_pane: string, start: path] {
      let chooser = (mktemp --tmpdir "hx-yazi.XXXXXX")
      ^${lib.getExe config.programs.yazi.package} $start --chooser-file $chooser
      let paths = (open --raw $chooser | lines | where {|p| $p | is-not-empty })
      rm --force $chooser
      if ($paths | is-not-empty) {
        let args = ($paths | each {|p| $'"($p)"' } | str join " ")
        ^${zellij} action write-chars --pane-id $helix_pane $":open ($args)\r"
      }
    }
  '';

  # Bound in Helix; returns at once so Helix stays responsive while picking.
  yaziPicker = pkgs.writeNuScriptBin "hx-yazi" ''
    def main [buffer: string = ""] {
      if ($env.ZELLIJ_PANE_ID? | is-empty) {
        error make { msg: "hx-yazi opens Yazi in a Zellij floating pane; start Helix inside Zellij" }
      }
      let start = if ($buffer | is-not-empty) and ($buffer | path exists) { $buffer | path expand } else { $env.PWD }
      (
        ^${zellij} run --floating --close-on-exit --name yazi
          --width 90% --height 90% -x 5% -y 5%
          -- ${lib.getExe yaziPick} $env.ZELLIJ_PANE_ID $start
      ) | ignore
    }
  '';
in
{
  programs.helix = {
    enable = config.dotfiles.alternates || config.dotfiles.primary.editor == "helix";
    extraPackages = with pkgs; [
      nixd
      nil
      nixfmt
      marksman
      taplo
      dhall
    ];
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
          # Pick files with Yazi, starting at the current buffer.
          C-y = ":sh ${lib.getExe yaziPicker} '%{buffer_name}'";
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
              home-manager.expr = "(builtins.getFlake (builtins.toString ./.)).nixosConfigurations.asus.options.home-manager.users.type.getSubOptions []";
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

  dotfiles.tooling.editors.helix.command = "${pkgs.helix}/bin/hx";
}
