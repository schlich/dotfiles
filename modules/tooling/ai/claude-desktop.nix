{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # Apply the overlay to this configuration's pkgs rather than using the
  # flake's packages output: that output imports nixpkgs without allowUnfree,
  # so the proprietary package would fail to evaluate.
  claude-desktop = (inputs.llm-agents.overlays.shared-nixpkgs pkgs pkgs).llm-agents.claude-desktop;
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "claude") {
  home.packages = [ claude-desktop ];
}
