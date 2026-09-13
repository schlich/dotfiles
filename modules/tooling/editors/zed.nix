{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  skills = import ../ai/shared-skills.nix { inherit inputs; };
in

{
  # Zed discovers global instructions from ~/.config/zed/AGENTS.md and
  # reusable skills from ~/.agents/skills. Share both with the other clients.
  home.file = {
    ".config/zed/AGENTS.md".source = ../ai/global-agent-instructions.md;
  }
  // lib.mapAttrs' (
    name: source:
    lib.nameValuePair ".agents/skills/${name}" {
      inherit source;
      recursive = true;
    }
  ) skills;

  programs.zed-editor = {
    enable = true;
    userSettings = {
      # This covers Zed's built-in terminal and task runner. ACP agent tool
      # shells are selected independently by Zed and currently cannot be
      # overridden through its settings.
      terminal.shell.program = "${pkgs.nushell}/bin/nu";

      context_servers.nushell = {
        command = "${pkgs.nushell}/bin/nu";
        args = [ "--mcp" ];
      };

      lsp.nil.settings.nil.nix.flake.autoArchive = true;
      lsp.nil.settings.nil.nix.flake.autoEvalInputs = true;

      # Ty supplies Python type-checking diagnostics; Ruff supplies
      # formatting and linting. This also excludes Zed's default BasedPyright.
      languages.Python.language_servers = [
        "ruff"
        "!basedpyright"
      ];

      agent_servers.codex-acp = {
        type = "registry";
        favorite_config_option_values.collaboration_mode = [ "default" ];
        default_config_options.collaboration_mode = "default";
      };

      agent = {
        sandbox_permissions = {
          allow_unsandboxed = true;
          allow_fs_write_all = true;
        };
        default_model = {
          provider = "zed.dev";
          model = "gpt-5.6-sol";
          enable_thinking = true;
          effort = "medium";
        };
        favorite_models = [ ];
        model_parameters = [ ];
      };
    };
  };

  dotfiles.tooling.editors.zed.command = "${pkgs.zed-editor}/bin/zeditor";
}
