{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  skills = import ../ai/shared-skills.nix { inherit inputs; };
  atuin = import ../../programs/atuin-package.nix { inherit inputs pkgs; };
  # $EDITOR callers (jj, Nushell's Ctrl+O, Yazi) need the editor to block
  # until the file closes. Without a graphical session, such as over SSH or
  # on a TTY, Zed cannot open a window, so Helix takes over there.
  zedOrHelix = pkgs.writeNuScriptBin "zed-or-helix" ''
    def --wrapped main [...args] {
      if ($env.WAYLAND_DISPLAY? | is-empty) or ($env.SSH_CONNECTION? | is-not-empty) {
        exec ${config.dotfiles.tooling.editors.helix.command} ...$args
      } else {
        exec ${pkgs.zed-editor}/bin/zeditor --wait ...$args
      }
    }
  '';
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
    enable = config.dotfiles.alternates || config.dotfiles.primary.editor == "zed";
    extraPackages = with pkgs; [
      nixd
      nil
    ];
    userSettings = {
      helix_mode = true;

      # This covers Zed's built-in terminal and task runner. ACP agent tool
      # shells are selected independently by Zed and currently cannot be
      # overridden through its settings.
      terminal.shell.program = "${pkgs.nushell}/bin/nu";

      context_servers.nushell = {
        command = "${pkgs.nushell}/bin/nu";
        args = [ "--mcp" ];
      };
      context_servers.atuin = {
        command = "${atuin}/bin/atuin";
        args = [ "mcp" ];
      };

      lsp.nil.settings.nil.nix.flake.autoArchive = true;
      # The same flake-aware option completion Helix's nixd setup gives.
      lsp.nixd.settings = {
        nixpkgs.expr = "import (builtins.getFlake (builtins.toString ./.)).inputs.nixpkgs { }";
        options = {
          nixos.expr = "(builtins.getFlake (builtins.toString ./.)).nixosConfigurations.asus.options";
          home-manager.expr = "(builtins.getFlake (builtins.toString ./.)).homeConfigurations.\"schlich@asus\".options";
        };
      };
      languages.Nix.language_servers = [
        "nixd"
        "nil"
      ];

      # Ty supplies Python type-checking diagnostics; Ruff supplies
      # formatting and linting. This also excludes Zed's default BasedPyright.
      languages.Python.language_servers = [
        "ruff"
        "!basedpyright"
      ];

      # External agents run the vendors' own harnesses, which sign in with
      # the Claude and ChatGPT subscriptions (`/login` in a new thread).
      agent_servers.claude-acp.type = "registry";
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
        # Zed's own agent uses the ChatGPT subscription (Sign in with OpenAI)
        # rather than Zed's hosted models.
        default_model = {
          provider = "openai-subscribed";
          model = "gpt-5.6-sol";
          enable_thinking = true;
          effort = "medium";
        };
        favorite_models = [ ];
        model_parameters = [ ];
      };
    };
  };

  dotfiles.tooling.editors.zed.command = "${zedOrHelix}/bin/zed-or-helix";
}
