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
  nixpkgsT3code =
    inputs.nixpkgs-t3code.legacyPackages.${pkgs.stdenv.hostPlatform.system}.t3code.override
      {
        enableCodex = false;
        enableGit = false;
        enableGitHub = false;
      };
  # T3 Connect, which carries push notifications to the phone, needs three
  # public values that official builds embed and nixpkgs' build lacks ("T3
  # Connect is unavailable in builds without public configuration"). The
  # server and `t3 connect` read them from the environment too. These come
  # from the official v0.1.4 server (t3-0.1.4-linux-x64.tar.gz, SHA-256
  # 8d759aff…): the relay, the Clerk publishable key of clerk.t3.codes, and
  # the Connect CLI's OAuth client, none of them secret. Recheck them when
  # moving to a release that changes T3 Connect.
  connectConfig = {
    T3CODE_RELAY_URL = "https://relay.t3.codes";
    T3CODE_CLERK_PUBLISHABLE_KEY = "pk_live_Y2xlcmsudDMuY29kZXMk";
    T3CODE_CLERK_CLI_OAUTH_CLIENT_ID = "hzxSgY2cH10sDU2r";
  };
  t3code = pkgs.symlinkJoin {
    name = "t3code-${nixpkgsT3code.version}";
    paths = [ nixpkgsT3code ];
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    postBuild = ''
      wrapProgram "$out/bin/t3" ${
        lib.concatStringsSep " " (
          lib.mapAttrsToList (name: value: "--set-default ${name} ${lib.escapeShellArg value}") connectConfig
        )
      }
    '';
    inherit (nixpkgsT3code) version meta;
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
