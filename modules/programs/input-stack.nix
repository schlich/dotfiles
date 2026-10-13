{
  config,
  lib,
  pkgs,
  ...
}:

# The nested keyboard namespaces from the desktop inward, each with one
# leader. docs/input.md explains the ownership rule.
let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.dotfiles.input;

  # Stable per scope, so inserting a context never moves another's leader.
  scopeLeaders = {
    global = "Super";
    application = "Alt";
    modal = "Space";
  };

  contextType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "[a-z][a-z0-9-]*";
        description = "Stable name for this input context.";
      };
      implementation = mkOption {
        type = types.str;
        description = "Application that implements this context.";
      };
      scope = mkOption {
        type = types.enum (builtins.attrNames scopeLeaders);
        description = "Semantic namespace this context owns.";
      };
      leader = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Explicit leader; null takes the scope's default.";
      };
    };
  };

  contexts = map (
    context:
    context
    // {
      leader = if context.leader == null then scopeLeaders.${context.scope} else context.leader;
    }
  ) cfg.contexts;
  names = map (context: context.name) contexts;
  leaders = map (context: context.leader) contexts;
  outer = if contexts == [ ] then null else builtins.head contexts;
  missing = builtins.filter (name: !(builtins.elem name names)) [
    "desktop"
    "terminal"
    "editor"
  ];
in
{
  options.dotfiles.input = {
    enable = mkEnableOption "the declarative nested input-context stack";
    contexts = mkOption {
      type = types.listOf contextType;
      default = [
        {
          name = "desktop";
          implementation = "niri";
          scope = "global";
        }
        {
          name = "terminal";
          implementation = config.dotfiles.primary.terminal;
          scope = "application";
        }
        {
          name = "editor";
          implementation = config.dotfiles.primary.editor;
          scope = "modal";
        }
      ];
      description = "Input contexts in order from outermost to innermost.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = "Input stack is missing required contexts: ${lib.concatStringsSep ", " missing}";
      }
      {
        assertion = names == lib.unique names;
        message = "Input context names must be unique: ${lib.concatStringsSep ", " names}";
      }
      {
        assertion = leaders == lib.unique leaders;
        message = "Input context leaders must be unique: ${lib.concatStringsSep ", " leaders}";
      }
      {
        assertion = !(builtins.elem "Ctrl" leaders);
        message = "Plain Ctrl cannot be an input-context leader.";
      }
      {
        assertion = outer != null && outer.implementation == "niri" && outer.leader == "Super";
        message = "The outermost input context must be Niri on Super.";
      }
    ];

    # The static hierarchy, for hint bars and mode indicators to read.
    xdg.dataFile."input-stack.json".source = pkgs.writeText "input-stack.json" (
      builtins.toJSON {
        version = 1;
        propagation = "outer contexts consume only their own namespace before forwarding inward";
        contexts = map (context: {
          inherit (context)
            name
            implementation
            scope
            leader
            ;
        }) contexts;
      }
    );
  };
}
