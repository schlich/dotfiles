{
  config,
  lib,
  pkgs,
  ...
}:

let
  builder = import ../../hosts/homelab/builder.nix // {
    hostName = config.dotfiles.fleet.hosts.homelab.fqdn;
  };
  sshKey = "/root/.ssh/homelab-builder";
in
{
  # Hand builds to homelab, which fetches their inputs from its own caches
  # instead of receiving them from here. Until this host's key is listed in
  # hosts/homelab/builder.nix, or while homelab is unreachable, Nix gives up
  # on it within seconds and builds locally.
  # homelab serves the cache and the builder together and does not build on
  # itself. (users.users cannot gate this: it depends on nix.settings.)
  config = lib.mkIf (!config.services.harmonia.cache.enable) {
    # Each host makes its own key the first time and keeps it under /root,
    # which survives impermanence. The public half is copied to
    # /run/homelab-builder.pub at every boot for adding to clientKeys.
    systemd.services.homelab-builder-key = {
      description = "Create this host's key for building on homelab";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        if [ ! -e ${sshKey} ]; then
          install -d -m 0700 /root/.ssh
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -C nix-builder@${config.networking.hostName} -f ${sshKey}
        fi
        install -m 0644 ${sshKey}.pub /run/homelab-builder.pub
      '';
    };

    nix = {
      distributedBuilds = true;
      buildMachines = [
        {
          hostName = "homelab-builder";
          protocol = "ssh-ng";
          system = "x86_64-linux";
          sshUser = builder.user;
          inherit sshKey;
          # homelab runs two jobs of four cores each, like every host.
          maxJobs = 2;
          supportedFeatures = [
            "nixos-test"
            "benchmark"
            "big-parallel"
            "kvm"
          ];
        }
      ];
      settings.builders-use-substitutes = true;
    };

    programs.ssh = {
      extraConfig = ''
        Host homelab-builder
          HostName ${builder.hostName}
          Port ${toString builder.port}
          ConnectTimeout 5
      '';
      knownHosts.homelab-builder = {
        hostNames = [ "[${builder.hostName}]:${toString builder.port}" ];
        publicKey = builder.hostKey;
      };
    };
  };
}
