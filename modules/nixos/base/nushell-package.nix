# Nushell 0.117.0 ahead of nixpkgs, which ships 0.116.1 until
# NixOS/nixpkgs#586153 lands. The hashes are that pull request's; 0.117.0
# also drops both of nixpkgs' patches, which upstream now carries.
# dotfiles.nixpkgsWatch.nushell (modules/programs/shell/shell.nix) warns once
# the locked nixpkgs ships it; then delete this file and its two imports
# (modules/nixos/base/user.nix and flake.nix).
#
# An overlay, so the login shell, every `pkgs.nushell` in hooks and checks,
# and writeNuScriptBin (nushellWith, which takes `final.nushell`) agree.
final: prev: {
  nushell = prev.nushell.overrideAttrs (
    finalAttrs: _: {
      version = "0.117.0";
      src = final.fetchFromGitHub {
        owner = "nushell";
        repo = "nushell";
        tag = finalAttrs.version;
        hash = "sha256-+lA9T0Wa/K50qCfyGFdNlEmCZWCeBk8KcxIvDCKk2no=";
      };
      patches = [ ];
      cargoPatches = [ ];
      cargoHash = "sha256-0t1ubpyPiXucUlJ+Nwu2u3LZ15GtX6mF2kMy9HkbClw=";
    }
  );
}
