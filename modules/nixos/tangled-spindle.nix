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
  # the host.
  guest = image.inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      image.nixosModules.spindle-nixos
      {
        microvm.mem = image.inputs.nixpkgs.lib.mkForce 10240;
        microvm.vcpu = image.inputs.nixpkgs.lib.mkForce 6;
      }
    ];
  };
  nixosImage = imagePkgs.callPackage "${image}/nix/pkgs/spindle-nixos-image.nix" {
    nixosSystem = guest;
  };
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
      workflowTimeout = "30m";
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
