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

  # The hub on homelab (github:schlich/honeycomb, modules/nixos/homelab), on
  # the tailnet name that den/inventory.nix gives as network.tailnet.
  inherit (inputs.honeycomb.overlays.default pkgs pkgs) honeycomb;
  hub = "https://homelab.tail338351.ts.net:7444";
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "claude") {
  home.packages = [ claude-desktop ];

  # Every minute, send the phone's honeycomb what each area holds and apply
  # the archiving and filing queued there, which waits while the app runs.
  systemd.user.services.honeycomb-hub-sync = {
    Unit.Description = "Send the honeycomb hub this host's areas and apply the phone's actions";
    Service = {
      Type = "oneshot";
      Environment = [
        "HONEYCOMB_HUB=${hub}"
        "PATH=${lib.makeBinPath [ pkgs.git ]}:%h/.nix-profile/bin:/etc/profiles/per-user/%u/bin:/run/current-system/sw/bin"
      ];
      ExecStart = "${lib.getExe honeycomb} hub sync";
    };
  };
  systemd.user.timers.honeycomb-hub-sync = {
    Unit.Description = "Keep the honeycomb hub current";
    Timer = {
      OnStartupSec = "1min";
      OnUnitActiveSec = "1min";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  dotfiles.nixpkgsWatch.claude-desktop = {
    # An FHS wrapper need not carry a version; then any nixpkgs package counts.
    version = claude-desktop.version or null;
    reason = "build claude-desktop from pkgs in modules/tooling/ai/claude/claude-desktop.nix (keeping the libsecret override) and drop the llm-agents input if nothing else uses it";
  };
}
