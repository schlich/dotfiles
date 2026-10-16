{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # asus administers homelab; modules/nixos/user.nix authorizes its login.
  adminKey = (import ../../hosts/login-keys.nix).asus;

  fieldnotes = import ../tooling/ai/fieldnotes-package.nix { inherit inputs lib pkgs; };

  # Servers lack the nushellWith overlay behind writeNuScriptBin.
  verificationReceiver = pkgs.writers.writeNuBin "receive-verification" (
    builtins.readFile ../../jj/receive-verification.nu
  );

  ciPackage = inputs.ci.packages.${pkgs.stdenv.hostPlatform.system}.ci;

  ciDashboard = pkgs.runCommand "ci-dashboard" { } ''
    mkdir -p "$out/share/ci-dashboard"
    cp ${../../tools/ci-dashboard/index.html} "$out/share/ci-dashboard/index.html"
    cp ${../../tools/ci-dashboard/server.mjs} "$out/share/ci-dashboard/server.mjs"
    cp ${../../tools/ci-dashboard/feeds.mjs} "$out/share/ci-dashboard/feeds.mjs"
  '';

  # Niri's own default config, minus its waybar autostart: homelab has no
  # waybar, and the desktop session instead starts the monitor terminal.
  niriConfig = pkgs.runCommand "niri-homelab-config.kdl" { } ''
    substitute ${config.programs.niri.package.src}/resources/default-config.kdl $out \
      --replace-fail 'spawn-at-startup "waybar"' '// The monitor terminal starts as a systemd user service.'
  '';
in
{
  networking.hostName = "homelab";
  networking.networkmanager.enable = true;

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
    helix
    smartmontools
    tmux
    # homelab has no Home Manager Niri config, so Niri's built-in defaults
    # bind these as its terminal and launcher.
    alacritty
    fuzzel
  ];

  # homelab has no Home Manager, so Niri reads this system-wide config.
  environment.etc."niri/config.kdl".source = niriConfig;

  # The browser feed is local-only; Tailscale Serve publishes it on a
  # separate HTTPS port for tailnet devices, leaving the existing public
  # Funnel on 443 untouched.
  # Its CI panel reads GitHub Actions through gh, which authenticates with the
  # token in schlich's ~/.config/gh/hosts.yml, as Fieldnotes does.
  systemd.services.ci-dashboard = {
    description = "Read-only CI dashboard";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      User = "schlich";
      WorkingDirectory = "/home/schlich/dotfiles";
      Environment = [
        "CI_REPO=/home/schlich/dotfiles"
        "CI_GITHUB_REPO=schlich/dotfiles"
        "HOME=/home/schlich"
        "PATH=${ciPackage}/bin:${pkgs.gh}/bin:/run/current-system/sw/bin"
        "PORT=4173"
      ];
      ExecStart = "${pkgs.nodejs}/bin/node ${ciDashboard}/share/ci-dashboard/server.mjs";
      Restart = "on-failure";
      RestartSec = "5s";
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
  };

  # This is Tailscale Serve, not Funnel: only tailnet devices can reach it.
  # The dedicated port keeps the existing root route and Funnel configuration
  # on 443 independent from the dashboard.
  systemd.services.ci-dashboard-serve = {
    description = "Publish the CI dashboard privately on the tailnet";
    wantedBy = [ "multi-user.target" ];
    requires = [
      "ci-dashboard.service"
      "tailscaled.service"
    ];
    after = [
      "ci-dashboard.service"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --https=8443 http://127.0.0.1:4173";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=8443 off";
      Restart = "on-failure";
      RestartSec = "10s";
    };
  };

  # The Fieldnotes dashboard fills the desktop; `fieldnotes` also runs over SSH.
  systemd.user.services.desktop-monitor = {
    description = "Fieldnotes dashboard for agent usage, CI, topics, and tasks";
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    after = [ "graphical-session.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.alacritty}/bin/alacritty --title Fieldnotes -e ${lib.getExe fieldnotes}";
      Environment = [ "FIELDNOTES_CI_REPO=schlich/dotfiles" ];
      Restart = "on-failure";
      RestartSec = 2;
    };
  };
}
