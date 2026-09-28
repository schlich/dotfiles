{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Yazi takes over Helix's terminal (it draws on /dev/tty), writes the chosen
  # paths to a chooser file, and leaves the alternate screen on exit; `pick`
  # restores the screen and bracketed paste for Helix, and `paths` hands the
  # choice to :open.
  yaziPicker = pkgs.writeNuScriptBin "hx-yazi" ''
    def chooser [] {
      $"($env.XDG_RUNTIME_DIR? | default $env.TMPDIR? | default "/tmp")/hx-yazi-chooser"
    }

    def "main pick" [buffer: string = ""] {
      let start = if ($buffer | is-not-empty) and ($buffer | path exists) { $buffer | path expand } else { $env.PWD }
      rm --force (chooser)
      ^${lib.getExe config.programs.yazi.package} $start --chooser-file (chooser)
      $"(ansi --escape '?1049h')(ansi --escape '?2004h')" | save --raw --append /dev/tty
    }

    def "main paths" [] {
      if ((chooser) | path exists) {
        open --raw (chooser) | lines | where {|p| $p | is-not-empty } | str join "\n"
      }
    }

    def main [] {}
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
          C-y = [
            ":insert-output ${lib.getExe yaziPicker} pick '%{buffer_name}'"
            ":open %sh{${lib.getExe yaziPicker} paths}"
            ":redraw"
            # Re-enable mouse capture, which Yazi turns off on exit.
            ":set mouse false"
            ":set mouse true"
          ];
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
