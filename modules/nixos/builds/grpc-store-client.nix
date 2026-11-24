{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  classicNix = config.iets.classic.nix or config.nix.package;
  dispatcher = config.programs.nix-grpc-store.package;
in
{
  imports = [ inputs.nix-grpc-store.nixosModules.client ];

  programs.nix-grpc-store = {
    enable = true;
    # Build the plugin against the real Nix: on workstations nix.package is
    # iets's front, which has no libs and runs the real Nix for what it lacks.
    packageSet = pkgs.callPackage "${inputs.nix-grpc-store}/nix/packages" {
      nixPackages = classicNix.libs;
    };
  };

  # iets falls back on plugin-files even for evaluation without a remote store.
  # Use nix-with-plugin for standard Nix copies and queries against grpc://.
  nix.settings.plugin-files = lib.mkIf (config.iets.classic.enable or false) (lib.mkForce [ ]);
  environment.systemPackages = lib.mkIf (config.iets.classic.enable or false) [
    (pkgs.writeShellScriptBin "nix-with-plugin" ''
      exec ${lib.getExe' classicNix "nix"} --option plugin-files ${dispatcher}/lib/nix/plugins "$@"
    '')
  ];
}
