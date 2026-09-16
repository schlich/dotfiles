{
  inputs,
  pkgs,
  ...
}:

{
  imports = [ inputs.tangled.nixosModules.spindle ];

  services.tangled = {
    knot = {
      enable = true;
      gitUser = "git";
    };
    spindle = {
      enable = true;
      server = {
        owner = "did:plc:3ta3pjip7mu36b7dnznhoyri";
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
