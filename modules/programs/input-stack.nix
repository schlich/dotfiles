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

  # The eight navigation keys every context shares (lib/honeycomb): six
  # directions and two depths.
  honeycomb = import ../../lib/honeycomb { inherit lib; };
  # Every chord a context declares for a seat that ends on another key.
  strayChords = honeycomb.strayChords cfg.navigation;
  unknownNavigation = builtins.filter (name: !(builtins.elem name names)) (
    builtins.attrNames cfg.navigation
  );
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
          name = "multiplexer";
          implementation = "luvus";
          scope = "application";
          leader = "Ctrl+Space";
        }
        {
          name = "editor";
          implementation = config.dotfiles.primary.editor;
          scope = "modal";
        }
      ];
      description = "Input contexts in order from outermost to innermost.";
    };
    navigation = mkOption {
      type = types.attrsOf (types.attrsOf (types.listOf types.str));
      default = { };
      example = {
        terminal.w = [ "Alt+H" ];
      };
      description = ''
        The chords each context binds to the shared navigation keys, by
        context name and then by seat: the six directions (`w`, `e`, `nw`,
        `ne`, `sw`, `se`), `inward` and `outward`. Evaluation fails when a
        chord ends on a key other than the seat's, so a direction means the
        same key in every tool.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Niri's navigation comes from its bind tree.
    dotfiles.input.navigation.desktop = (import ../../niri/binds.nix { inherit lib; }).navigation;

    assertions = [
      {
        assertion = strayChords == [ ];
        message = "Navigation keys differ from the honeycomb's: ${lib.concatStringsSep "; " strayChords}";
      }
      {
        assertion = unknownNavigation == [ ];
        message = "Navigation is declared for contexts that do not exist: ${lib.concatStringsSep ", " unknownNavigation}";
      }
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
        version = 2;
        propagation = "outer contexts consume only their own namespace before forwarding inward";
        # The navigation grammar every context shares.
        honeycomb = {
          inherit (honeycomb) limit keys modes;
        };
        contexts = map (context: {
          inherit (context)
            name
            implementation
            scope
            leader
            ;
          navigation = cfg.navigation.${context.name} or { };
        }) contexts;
      }
    );
  };
}
