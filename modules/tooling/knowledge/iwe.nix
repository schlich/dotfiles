{
  config,
  lib,
  pkgs,
  ...
}:

let
  sshClient = import ../../programs/ssh/ssh-client.nix { inherit lib pkgs; };
  kbSync = pkgs.writeShellApplication {
    name = "kb-sync";
    runtimeInputs = [
      pkgs.nushell
      pkgs.jujutsu
      pkgs.git
      pkgs.util-linux
      pkgs.coreutils
      sshClient
    ];
    text = ''
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

  # Keep ~/Research/kb synchronized across hosts through the private Git remote
  # on homelab. Runs quietly as a no-op until the repo and remote exist.
  systemd.user.services.kb-sync = {
    Unit = {
      Description = "Sync the personal knowledge base with its private Git remote";
      After = [ "network-online.target" ];
      Wants = [ "network-online.target" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${lib.getExe kbSync}";
      TimeoutStartSec = "60s";
      Environment = [
        "KB_ROOT=${config.dotfiles.paths.kb}"
      ]
      ++ lib.optional config.services.gnome-keyring.enable "SSH_AUTH_SOCK=%t/gcr/ssh";
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
        export XDG_RUNTIME_DIR="$TMPDIR/run"
        mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
        nu --no-config-file ${./kb-sync-test.nu} ${./kb-sync.nu}
        touch "$out"
      '';
}
