{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # asus administers homelab; modules/nixos/base/user.nix authorizes its login.
  adminKey = (import ../../../hosts/login-keys.nix).asus;

  fieldnotes = import ../../tooling/ai/claude/fieldnotes-package.nix { inherit inputs lib pkgs; };

  # Servers lack the nushellWith overlay behind writeNuScriptBin.
  verificationReceiver = pkgs.writers.writeNuBin "receive-verification" (
    builtins.readFile ../../../jj/receive-verification.nu
  );

  # Niri's own default config, minus its waybar autostart, with Ghostty in
  # place of Alacritty on Mod+T: homelab has no waybar, and the desktop
  # session instead starts the monitor terminal.
  niriConfig = pkgs.runCommand "niri-homelab-config.kdl" { } ''
    substitute ${config.programs.niri.package.src}/resources/default-config.kdl $out \
      --replace-fail 'spawn-at-startup "waybar"' '// The monitor terminal starts as a systemd user service.' \
      --replace-fail 'hotkey-overlay-title="Open a Terminal: alacritty" { spawn "alacritty"; }' \
        'hotkey-overlay-title="Open a Terminal: Ghostty" { spawn "ghostty"; }'
  '';

  # The digest's credentials, which the owner encrypts with agenix
  # (tools/discord-digest/README.md). The digest stays off until they exist.
  discordDigestSecret = ../../../secrets/discord-digest/env.age;
  discordDigestReady = builtins.pathExists discordDigestSecret;
in
{
  imports = [
    ./discord-digest.nix
    inputs.honeycomb.nixosModules.hub
    ./honeycomb-hub.nix
    ../../tooling/knowledge/kb-git/module.nix
  ];

  # homelab keeps its own checkout at the top of its home; only asus's home
  # moved into the honeycomb area folders.
  dotfiles.checkout = "/home/schlich/dotfiles";

  # The phone's view of the seven areas, which asus keeps current
  # (github:schlich/honeycomb), published on the tailnet by honeycomb-hub.nix.
  services.honeycomb-hub.enable = true;

  # Private Tailscale Serve HTTPS remote for ~/Research/kb so asus and homelab
  # sync without SSH keys or port-2222 plumbing.
  services.kb-git.enable = true;

  services.discord-digest = lib.mkIf discordDigestReady {
    enable = true;
    environmentFile = config.age.secrets.discord-digest-env.path;
  };
  age.secrets = lib.mkIf discordDigestReady {
    discord-digest-env.file = discordDigestSecret;
  };
  warnings = lib.optional (!discordDigestReady) ''
    discord-digest is off on homelab: secrets/discord-digest/env.age does not
    exist yet. tools/discord-digest/README.md says how to create it.
  '';

  networking.hostName = "homelab";
  networking.networkmanager.enable = true;
  # Helix, which homelab installs, rather than NixOS's default nano, and
  # Ghostty as the terminal fuzzel and other launchers open.
  environment.variables = {
    EDITOR = "hx";
    VISUAL = "hx";
    TERMINAL = "ghostty";
  };
  # Desktop entries with Terminal=true open in Ghostty too.
  xdg.terminal-exec = {
    enable = true;
    settings.default = [ "com.mitchellh.ghostty.desktop" ];
  };

  # sudo also accepts asus's login key from a forwarded SSH agent and falls
  # back to the password without one. Its root-owned key list is separate from
  # SSH logins, so a new login key does not also grant sudo.
  security.pam = {
    sshAgentAuth = {
      enable = true;
      authorizedKeysFiles = [ "/etc/ssh/sudo_authorized_keys" ];
    };
    services.sudo.sshAgentAuth = true;
  };
  # A copy, not a store symlink: pam_ssh_agent_auth rejects a key file under
  # a group-writable directory, which /nix/store is.
  environment.etc."ssh/sudo_authorized_keys" = {
    mode = "0444";
    text = ''
      ${adminKey}
    '';
  };

  # `ci verify` on each host sends one record per verified release here. The
  # account can only run the receiver, which appends to
  # /var/lib/config-verifications/<host>.jsonl; `restrict` also denies a
  # shell, forwarding, and a terminal.
  users.users.config-verifications = {
    isSystemUser = true;
    group = "config-verifications";
    home = "/var/lib/config-verifications";
    createHome = true;
    # sshd runs the forced command through the login shell.
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      ''restrict,command="${verificationReceiver}/bin/receive-verification" ${adminKey}''
    ];
  };
  users.groups.config-verifications = { };
  # Tailscale SSH answers port 22 on the tailnet address and never reads
  # authorized_keys, so the forced command above would not apply there.
  # OpenSSH also listens on this port, which Tailscale leaves alone.
  services.openssh = {
    ports = [
      22
      2222
    ];
    settings.AllowUsers = [ "config-verifications" ];
  };

  # Keep the machine running when its broken lid is closed or a power key is
  # pressed. A long hardware power-button hold remains an emergency shutdown.
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
    HandlePowerKey = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
  };

  # Remote access should stay on the private LAN/Tailscale network; do not
  # expose SSH through the router.
  services.tailscale.enable = true;

  environment.systemPackages = with pkgs; [
    fieldnotes
    btop
    # FlakeHub's CLI, from nixpkgs as on the workstation.
    fh
    helix
    smartmontools
    tmux
    # homelab has no Home Manager Niri config, so Niri's built-in defaults
    # bind these as its terminal and launcher; niriConfig swaps Alacritty
    # for Ghostty.
    ghostty
    fuzzel
  ];

  # homelab has no Home Manager, so Niri reads this system-wide config.
  environment.etc."niri/config.kdl".source = niriConfig;

  # The Fieldnotes dashboard fills the desktop; `fieldnotes` also runs over SSH.
  systemd.user.services.desktop-monitor = {
    description = "Fieldnotes dashboard for agent usage, CI, topics, and tasks";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.ghostty} --title=Fieldnotes -e ${lib.getExe fieldnotes}";
      Environment = [ "FIELDNOTES_CI_REPO=schlich/dotfiles" ];
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
