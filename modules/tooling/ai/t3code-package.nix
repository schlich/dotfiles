{
  inputs,
  lib,
  pkgs,
  ...
}:

# T3 Code from the nixpkgs-t3code input (flake.nix), the one package the
# desktop client (t3code.nix) and the fleet server (t3code-server.nix) both
# run, so `t3`, the app and the service always match. The wrapper prepends
# nothing to PATH: Claude Code and Codex sign in with their subscriptions
# through the profile's configured `claude` and `codex`, and git and gh come
# from the profile wrappers that carry the identity and credential helper
# (vcs.nix, cli.nix).

let
  t3code = inputs.nixpkgs-t3code.legacyPackages.${pkgs.stdenv.hostPlatform.system}.t3code.override {
    enableCodex = false;
    enableGit = false;
    enableGitHub = false;
  };
in
{
  options.dotfiles.t3code = {
    package = lib.mkOption {
      type = lib.types.package;
      default = t3code;
      defaultText = lib.literalExpression "inputs.nixpkgs-t3code.legacyPackages.\${system}.t3code";
      readOnly = true;
      description = "The T3 Code package that provides both `t3` and `t3code-desktop`.";
    };
    desktop = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether this home installs the T3 Code desktop app (t3code.nix).";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = t3code;
        defaultText = lib.literalExpression "config.dotfiles.t3code.package";
        description = ''
          The package t3code.nix installs for the desktop app. A host that
          also runs the fleet server sets one whose launcher starts the app as
          that server's client (t3code-server.nix).
        '';
      };
    };
  };

  config.dotfiles.nixpkgsWatch.t3code = {
    inherit (t3code) version;
    reason = "take t3code from pkgs in modules/tooling/ai/t3code-package.nix and drop the nixpkgs-t3code input";
  };
}
