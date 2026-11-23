{
  config,
  lib,
  pkgs,
  osConfig ? { },
  ...
}:

let
  homelabFqdn = osConfig.dotfiles.fleet.hosts.homelab.fqdn or "homelab.tail338351.ts.net";
  kbRemotePort = osConfig.dotfiles.tailscale.https.kb-git.port or 7445;
  kbRemoteUrl = "https://${homelabFqdn}:${toString kbRemotePort}/kb.git";
  kbSync = pkgs.writeShellApplication {
    name = "kb-sync";
    runtimeInputs = [
      pkgs.nushell
      config.programs.jujutsu.package
      config.programs.git.package
      pkgs.util-linux
      pkgs.coreutils
    ];
    text = ''
      export KB_REMOTE_URL="''${KB_REMOTE_URL:-${kbRemoteUrl}}"
      exec ${lib.getExe pkgs.nushell} --no-config-file ${./kb-sync.nu} "$@"
    '';
  };
in
{
  # The knowledge base lives in its own JJ repository at
  # dotfiles.paths.kb (~/Research/kb). Its
  # .iwe/config.toml, schemas, and MEMORY.md policy belong to that repository:
  # `iwe claude enable` and `/iwe:reflect` rewrite them at runtime.
  home.packages = [
    pkgs.iwe
    kbSync
  ];

  # Defined here and assigned to markdown only by the knowledge base's
  # .helix/languages.toml,
  # so other repositories' markdown keeps marksman alone.
  programs.helix.languages.language-server.iwe.command =
    lib.mkIf config.programs.helix.enable "${pkgs.iwe}/bin/iwes";

  programs.nushell.extraConfig = ''
    use ${../../../nushell/kb.nu} *
  '';

  # Keep ~/Research/kb synchronized across hosts through the private Tailscale
  # Serve HTTPS Git remote on homelab. Auto-adds the origin remote on existing
  # repos and auto-clones onto new hosts once main has been pushed.
  systemd.user.services.kb-sync = {
    Unit = {
      Description = "Sync the personal knowledge base over Tailscale HTTPS";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe kbSync}";
      TimeoutStartSec = "60s";
      Environment = [
        "KB_ROOT=${config.dotfiles.paths.kb}"
        "KB_REMOTE_URL=${kbRemoteUrl}"
      ];
    };
  };

  systemd.user.timers.kb-sync = {
    Unit.Description = "Periodically sync the personal knowledge base";
    Timer = {
      OnStartupSec = "30s";
      OnUnitActiveSec = "2m";
      AccuracySec = "15s";
    };
    Install.WantedBy = [ "timers.target" ];
  };

  dotfiles.tooling.checks.kb-sync =
    pkgs.runCommand "kb-sync-check"
      {
        nativeBuildInputs = [
          pkgs.nushell
          pkgs.jujutsu
          pkgs.git
          pkgs.util-linux
          pkgs.coreutils
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        nu --no-config-file ${./kb-sync-test.nu} ${./kb-sync.nu}
        touch "$out"
      '';

  dotfiles.tooling.checks.kb-git =
    pkgs.runCommand "kb-git-check"
      {
        nativeBuildInputs = [
          pkgs.nodejs
          pkgs.nushell
          pkgs.jujutsu
          pkgs.git
          pkgs.util-linux
          pkgs.coreutils
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        export KB_GIT_BACKEND="${pkgs.git}/bin/git-http-backend"
        mkdir -p "$HOME"
        node ${./kb-git/test.mjs} ${./kb-git/server.mjs} ${./kb-sync.nu}
        touch "$out"
      '';
}
