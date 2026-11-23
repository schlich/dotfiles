{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  nuPluginGhostty = import ./package.nix { inherit inputs lib pkgs; };
  # nu_plugin_ghostty links libghostty-vt 1.0.1, which nixpkgs does not ship
  # yet, so this home builds it (./libghostty-vt).
  libghosttyVt = pkgs.callPackage ./libghostty-vt/package.nix { };
in
{
  # Building the plugin runs its install check: a program's output read back
  # from a libghostty-vt terminal, in the build sandbox.
  dotfiles.tooling.checks.nu-plugin-ghostty = nuPluginGhostty;

  dotfiles.nixpkgsWatch = {
    libghostty-vt = {
      inherit (libghosttyVt) version;
      repo = "ghostty-org/ghostty";
      reason = "nu_plugin_ghostty needs libghostty-vt 1.0.1 (NixOS/nixpkgs#581882): delete modules/programs/shell/nu-plugin-ghostty/libghostty-vt/ and use pkgs.libghostty-vt in that directory's package.nix and default.nix, and in flake.nix";
    };
    nu-plugin-ghostty = {
      package = "nushellPlugins.ghostty";
      reason = "nixpkgs has no nu_plugin_ghostty: replace modules/programs/shell/nu-plugin-ghostty/package.nix with nixpkgs' package in that directory's default.nix and in flake.nix, and drop the nu-plugin-ghostty input";
    };
  };
}
