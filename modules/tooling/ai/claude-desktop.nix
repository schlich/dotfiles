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
  #
  # The app runs in an FHS sandbox and imports browser cookies by running
  # /usr/bin/secret-tool, a hardcoded path, to read Chrome's key from the
  # Secret Service keyring. Add libsecret to the sandbox to provide it.
  claude-desktop =
    (inputs.llm-agents.overlays.shared-nixpkgs pkgs pkgs).llm-agents.claude-desktop.override
      (prev: {
        buildFHSEnv =
          args:
          prev.buildFHSEnv (
            args // { targetPkgs = fhsPkgs: args.targetPkgs fhsPkgs ++ [ fhsPkgs.libsecret ]; }
          );
      });
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "claude") {
  home.packages = [ claude-desktop ];

  dotfiles.nixpkgsWatch.claude-desktop = {
    # An FHS wrapper need not carry a version; then any nixpkgs package counts.
    version = claude-desktop.version or null;
    reason = "build claude-desktop from pkgs in modules/tooling/ai/claude-desktop.nix (keeping the libsecret override) and drop the llm-agents input if nothing else uses it";
  };
}
