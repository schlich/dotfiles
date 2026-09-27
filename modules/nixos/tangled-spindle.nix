{
  inputs,
  pkgs,
  ...
}:

let
  image = inputs.tangled-image;
  system = pkgs.stdenv.hostPlatform.system;
  imagePkgs = import image.inputs.nixpkgs {
    inherit system;
    overlays = [ image.inputs.fetch-tangled.overlays.default ];
  };
  # Tangled's NixOS guest, built as its flake builds `spindle-nixos-image`
  # but larger: the stock 4 GiB, 2-vCPU guest runs nix-eval-jobs out of
  # memory on this repository's host checks. homelab has 15 GiB and 8 cores
  # and runs one workflow at a time, which leaves about 5 GiB and 2 cores for
  # the host. The stock 24 GiB /persist volume, which holds the writable
  # store, /tmp, and the workspace, fills up while building the desktop and
  # headless system checks; the sparse image grows on homelab's root disk.
  guest = image.inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      image.nixosModules.spindle-nixos
      {
        microvm.mem = image.inputs.nixpkgs.lib.mkForce 10240;
        microvm.vcpu = image.inputs.nixpkgs.lib.mkForce 6;
        microvm.volumes = image.inputs.nixpkgs.lib.mkForce [
          {
            image = "persist.img";
            mountPoint = "/persist";
            size = 96 * 1024;
            fsType = "ext4";
          }
        ];
      }
    ];
  };
  nixosImage = imagePkgs.callPackage "${image}/nix/pkgs/spindle-nixos-image.nix" {
    nixosSystem = guest;
  };

  # Workflow guests build in their own store, so without a cache every run
  # whose flake.lock differs starts cold. Spindle imports each path a guest
  # builds into this host's store as the guest commits it, which keeps work
  # from a run that times out, and Harmonia serves that store back to later
  # guests. Imported paths are unrooted, so the weekly GC resets the cache.
  harmoniaAddress = "127.0.0.1:5000";
  # The secret half was generated on the host and never enters the
  # repository or the store; to rotate it, rerun this on homelab and
  # replace cachePublicKey with what it prints:
  #   nix key generate-secret --key-name homelab-cache-1 | sudo tee /var/lib/harmonia-secrets/signing-key | nix key convert-secret-to-public
  cacheSigningKey = "/var/lib/harmonia-secrets/signing-key";
  cachePublicKey = "homelab-cache-1:iRxSmTDiOFX6oY5jLwiUiXCNJ5KSfHtmJBG7RDzLDaQ=";
in
{
  imports = [ inputs.tangled.nixosModules.spindle ];

  services.tangled.spindle = {
    enable = true;
    server = {
      # The account DID that registers this spindle on tangled.org, which
      # verifies it against the spindle's reported owner. A repository DID
      # (such as dotfiles' did:plc:3ta3pjip7mu36b7dnznhoyri) cannot own one.
      owner = "did:plc:cnyy2sz5ddr4gls245vjgbrd";
      hostname = "homelab.tail338351.ts.net";
      listenAddr = "127.0.0.1:6555";
      queueSize = 10;
      maxJobCount = 1;
    };
    pipelines = {
      # A run after a flake.lock change rebuilds whatever the cache lacks;
      # every path it finishes is kept, so the next run resumes from there.
      workflowTimeout = "2h";
      nixCache = {
        # Operator caches bypass spindle's address guard, so loopback works.
        # The guest reads these through spindle's proxy; keep cache.nixos.org
        # listed so the proxy never becomes the guest's only, narrower cache.
        readUrls = [
          "http://${harmoniaAddress}"
          "https://cache.nixos.org"
        ];
        trustedPublicKeys = [
          cachePublicKey
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
        ];
        # Spindle runs as root, which the Nix daemon trusts to import the
        # guest's unsigned paths; Harmonia signs them when serving.
        uploadUrl = "daemon";
      };
      microvm = {
        defaultImage = "nixos";
        # Spindle resolves an image name to `<imageDir>/<name>/spec.json`, so
        # serve the guest from the store instead of files installed by hand.
        imageDir = "${pkgs.linkFarm "spindle-images" [
          {
            name = "nixos";
            path = nixosImage;
          }
        ]}";
      };
    };
  };

  services.harmonia.cache = {
    enable = true;
    signKeyPaths = [ cacheSigningKey ];
    settings.bind = harmoniaAddress;
  };

  systemd.tmpfiles.rules = [ "d /var/lib/harmonia-secrets 0700 root root -" ];

  # tangled.org reaches the spindle only through this Funnel: it verifies the
  # owner and dispatches pipelines at https://${hostname}. Funnel needs a
  # one-time `tailscale up` and the tailnet's funnel node attribute; until
  # then this unit fails without affecting the spindle itself.
  systemd.services.tangled-spindle-funnel = {
    description = "Tailscale Funnel for the Tangled spindle";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale funnel --bg 6555";
      ExecStop = "${pkgs.tailscale}/bin/tailscale funnel 6555 off";
    };
  };
}
