{
  config,
  inputs,
  pkgs,
  ...
}:

{
  imports = [ inputs.nix-grpc-store.nixosModules.client ];

  # Loads the grpc:// store plugin into every nix invocation, for example
  #   nix copy --to grpc://homelab.<tailnet>:50051 ./result
  # (hosts/homelab/grpc-store.nix). The loader picks the plugin build that
  # matches the running Nix and disables grpc:// on a mismatch instead of
  # failing, so it is safe everywhere.
  programs.nix-grpc-store = {
    enable = true;
    # Build the plugin against the real Nix: on workstations nix.package is
    # iets's front, which has no libs and runs the real Nix for what it lacks.
    packageSet = pkgs.callPackage "${inputs.nix-grpc-store}/nix/packages" {
      nixPackages = (config.iets.classic.nix or config.nix.package).libs;
    };
  };
}
