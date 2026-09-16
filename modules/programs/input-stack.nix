{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;
  cfg = config.dotfiles.input;

  contextType = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "[a-z][a-z0-9-]*";
        description = "Stable name for this nested input context.";
      };
      implementation = mkOption {
        type = types.str;
        description = "Application or subsystem implementing this context.";
      };
      scope = mkOption {
        type = types.enum [
          "global"
          "application"
          "nested"
          "modal"
        ];
        description = "Semantic namespace owned by this context.";
      };
      leader = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Explicit leader; null selects the stable scope default.";
      };
    };
  };

  semanticDefaults = {
    global = "Super";
    application = "Alt";
    nested = "Ctrl+G";
    modal = "Space";
  };

  effectiveLeader =
    context: if context.leader == null then semanticDefaults.${context.scope} else context.leader;
  effectiveContexts = map (context: context // { leader = effectiveLeader context; }) cfg.contexts;
  outerContext = if effectiveContexts == [ ] then null else builtins.head effectiveContexts;
  names = map (context: context.name) cfg.contexts;
  leaders = map (context: context.leader) effectiveContexts;
  required = [
    "desktop"
    "terminal"
    "multiplexer"
    "editor"
  ];
  missing = builtins.filter (name: !(builtins.elem name names)) required;
  metadata = pkgs.writeText "input-stack.json" (
    builtins.toJSON {
      version = 1;
      hierarchy = [
        "desktop"
        "terminal"
        "multiplexer"
        "editor"
      ];
      propagation = "outer contexts consume only their owned namespace before forwarding inward";
      contexts = map (context: {
        inherit (context)
          name
          implementation
          scope
          leader
          ;
      }) effectiveContexts;
    }
  );
  validation = pkgs.runCommand "input-stack-check" { nativeBuildInputs = [ pkgs.jq ]; } ''
    jq --exit-status '
      .version == 1 and
      ([.contexts[].name] | unique | length == (.contexts | length)) and
      ([.contexts[].leader] | unique | length == (.contexts | length)) and
      ([.contexts[].implementation] | all(. != "")) and
      ([.contexts[].name] | index("desktop")) != null and
      ([.contexts[].name] | index("terminal")) != null and
      ([.contexts[].name] | index("multiplexer")) != null and
      ([.contexts[].name] | index("editor")) != null
    ' ${metadata}
    touch "$out"
  '';
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
          implementation = "ghostty";
          scope = "application";
        }
        {
          name = "multiplexer";
          implementation = "zellij";
          scope = "nested";
        }
        {
          name = "editor";
          implementation = "helix";
          scope = "modal";
        }
      ];
      description = "Ordered, stable input contexts from outermost to innermost.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = missing == [ ];
        message = "Input stack is missing required contexts: ${builtins.concatStringsSep ", " missing}";
      }
      {
        assertion = leaders == lib.unique leaders;
        message = "Input context leaders must be unique: ${builtins.concatStringsSep ", " leaders}";
      }
      {
        assertion = outerContext != null && outerContext.leader == "Super";
        message = "The desktop/Niri context must retain Super as its global leader.";
      }
      {
        assertion = !(builtins.elem "Ctrl" leaders);
        message = "Plain Ctrl cannot be a global input-context leader.";
      }
      {
        assertion = outerContext != null && outerContext.implementation == "niri";
        message = "The outermost input context must be implemented by Niri.";
      }
    ];

    xdg.dataFile."input-stack.json".source = metadata;
    dotfiles.tooling.checks.input-stack = validation;
  };
}
