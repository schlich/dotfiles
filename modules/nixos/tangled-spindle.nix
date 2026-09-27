{
  inputs,
  pkgs,
  ...
}:

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
      microvm.defaultImage = "nixos";
    };
  };

  # Funnel requires one-time interactive Tailscale authentication and approval.
  # Start this unit manually after `tailscale up` on the homelab host.
  systemd.services.tangled-spindle-funnel = {
    description = "Tailscale Funnel for the Tangled spindle";
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
