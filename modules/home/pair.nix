{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nu-pair;
  pairScript = pkgs.writeNuScriptBin "pair" ''
    ${builtins.replaceStrings [ "source runtime.nu\n" "source inspect.nu\n" ] [ "" "" ] (
      builtins.readFile ./pair/mod.nu
    )}
    ${builtins.readFile ./pair/runtime.nu}
    ${builtins.readFile ./pair/inspect.nu}
  '';
  pairConfig = pkgs.writeText "nushell-pair-config.nu" ''
    ${builtins.replaceStrings [ "source runtime.nu\n" "source inspect.nu\n" ] [ "" "" ] (
      builtins.readFile ./pair/mod.nu
    )}
    ${builtins.readFile ./pair/runtime.nu}
    ${builtins.readFile ./pair/inspect.nu}
  '';
in
{
  options.programs.nu-pair = {
    enable = lib.mkEnableOption "Nushell code-mode runtime";
    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional pair state directory.";
    };
    jjIntegration = lib.mkEnableOption "JJ provenance hints in pair metadata";
    checkmateIntegration = lib.mkEnableOption "Checkmate integration hints in pair metadata";
  };
  config = lib.mkIf cfg.enable {
    home.packages = [ pairScript ];
    programs.nushell.extraConfig = "source ${pairConfig}";
    home.sessionVariables = lib.optionalAttrs (cfg.stateDir != null) { PAIR_STATE_DIR = cfg.stateDir; };
  };
}
