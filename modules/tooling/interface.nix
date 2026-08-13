{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkIf mkOption types;
  cfg = config.dotfiles;

  terminalType = types.submodule {
    options.launcher = mkOption {
      type = types.lines;
      description = "Nushell body used by the generic terminal launcher.";
    };
  };

  commandType = types.submodule {
    options.command = mkOption {
      type = types.str;
      description = "Absolute command exposed through the generic launcher.";
    };
  };

  aiType = types.submodule {
    options = {
      command = mkOption {
        type = types.str;
        description = "Absolute command exposed through the generic launcher.";
      };
      automation = mkOption {
        type = types.lines;
        description = "Nushell body used for non-interactive agent tasks.";
      };
    };
  };

  opencodePluginType = types.submodule {
    options = {
      source = mkOption {
        type = types.path;
        description = "Source file for an OpenCode plugin.";
      };
      target = mkOption {
        type = types.str;
        description = "Plugin filename in OpenCode's global plugin directory.";
      };
    };
  };

  terminal = cfg.tooling.terminals.${cfg.primary.terminal} or null;
  editor = cfg.tooling.editors.${cfg.primary.editor} or null;
  ai = cfg.tooling.ai.${cfg.primary.ai} or null;
in
{
  options.dotfiles = {
    primary = {
      terminal = mkOption {
        type = types.str;
        description = "Primary imported terminal tool.";
      };
      editor = mkOption {
        type = types.str;
        description = "Primary imported editor tool.";
      };
      ai = mkOption {
        type = types.str;
        description = "Primary imported AI harness.";
      };
    };

    tooling = {
      terminals = mkOption {
        type = types.attrsOf terminalType;
        default = { };
        internal = true;
      };
      editors = mkOption {
        type = types.attrsOf commandType;
        default = { };
        internal = true;
      };
      ai = mkOption {
        type = types.attrsOf aiType;
        default = { };
        internal = true;
      };
      opencodeConfig = mkOption {
        type = types.attrsOf opencodePluginType;
        default = { };
        internal = true;
      };
      checks = mkOption {
        type = types.attrsOf types.package;
        default = { };
        internal = true;
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = terminal != null;
        message = "Primary terminal '${cfg.primary.terminal}' is not imported by this profile.";
      }
      {
        assertion = editor != null;
        message = "Primary editor '${cfg.primary.editor}' is not imported by this profile.";
      }
      {
        assertion = ai != null;
        message = "Primary AI harness '${cfg.primary.ai}' is not imported by this profile.";
      }
    ];

    home.sessionVariables = {
      EDITOR = "editor";
      VISUAL = "editor";
      TERMINAL = "terminal";
      AI_HARNESS = "ai";
    };

    programs.nushell = {
      environmentVariables = {
        EDITOR = "editor";
        VISUAL = "editor";
      };
      extraConfig = ''
        $env.config.buffer_editor = "editor"
      '';
    };

    home.packages = mkIf (terminal != null && editor != null && ai != null) [
      (pkgs.nuenv.writeScriptBin {
        name = "terminal";
        script = ''
          def --wrapped main [
            --directory: path = "."
            --class: string = ""
            ...args
          ] {
            ${terminal.launcher}
          }
        '';
      })
      (pkgs.nuenv.writeScriptBin {
        name = "editor";
        script = ''
          def --wrapped main [...args] {
            ^${editor.command} ...$args
          }
        '';
      })
      (pkgs.nuenv.writeScriptBin {
        name = "ai";
        script = ''
          def --wrapped main [...args] {
            ^${ai.command} ...$args
          }
        '';
      })
      (pkgs.nuenv.writeScriptBin {
        name = "ai-run";
        script = ''
          def main [
            prompt: string
            --agent: string = "general"
          ] {
            ${ai.automation}
          }
        '';
      })
    ];
  };
}
