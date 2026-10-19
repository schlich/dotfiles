# marimohub configured for the executable-knowledge workbench on a tailnet
# host: kernels run in rootless Podman from the workbench's Nix images, and
# Tailscale Serve terminates HTTPS and supplies the signed-in identity.
{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  iwe = import ../tooling/knowledge/iwe-package.nix { inherit inputs lib pkgs; };
  workbench = import ../../workbench { inherit pkgs lib iwe; };
  cfg = config.services.marimohub;
  servePort = config.dotfiles.tailscale.https.marimohub.port;
in
{
  imports = [
    ./marimohub.nix
    ./tailscale-https.nix
  ];

  # Serve only, never Funnel: proxy-header auth trusts Tailscale-User-Login,
  # which Serve sets only for a signed-in tailnet user. A port outside
  # Funnel's 443, 8443 and 10000 leaves those for public endpoints.
  dotfiles.tailscale.https.marimohub.port = 9443;

  services.marimohub = {
    enable = true;
    package = import ../tooling/knowledge/marimohub-package.nix { inherit lib pkgs; };
    # `base` is the default image; a notebook needing another environment
    # selects it with the hub's "Change base image" action.
    compute.images = [
      workbench.environments.base.image
    ]
    ++ lib.mapAttrsToList (_: environment: environment.image) (
      removeAttrs workbench.environments [ "base" ]
    );
    auth = {
      backend = "proxy-header";
      proxyHeader = "Tailscale-User-Login";
    };
  };

  systemd.services.marimohub-serve = {
    description = "Tailscale Serve for marimohub";
    after = [
      "network-online.target"
      "tailscaled.service"
      "marimohub.service"
    ];
    wants = [
      "network-online.target"
      "tailscaled.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=${toString servePort} http://127.0.0.1:${toString cfg.port}";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=${toString servePort} off";
    };

    # Like the Funnel units, start this manually after `tailscale up` so a
    # logged-out client cannot fail an otherwise successful activation.
  };
}
