{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  # OpenCode 2 from upstream, since nixpkgs still ships 1.x. Upstream builds
  # for channel "prod", which registers the background service in
  # service-prod.json where clients look for service.json; "latest" is the
  # official release channel and keeps the same database. Upstream's source
  # fileset also leaves out script/native-arch.ts, which the CLI's build
  # script imports since 2.0.30 ("Cannot find module
  # '../../../script/native-arch'"), so copy it back in.
  opencode =
    inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system}.opencode.overrideAttrs
      (old: {
        postPatch = old.postPatch + ''
          install -Dm644 ${inputs.opencode}/script/native-arch.ts script/native-arch.ts
        '';
        env = old.env // {
          OPENCODE_CHANNEL = "latest";
        };
      });
  # The desktop build reuses the CLI's source but not its postPatch, and its
  # electron-builder config imports the same missing script
  # ("Cannot find module '../../script/native-arch'").
  opencode-desktop =
    (pkgs.callPackage (inputs.opencode + "/nix/desktop.nix") {
      inherit opencode;
    }).overrideAttrs
      (old: {
        postPatch = old.postPatch + ''
          install -Dm644 ${inputs.opencode}/script/native-arch.ts script/native-arch.ts
        '';
      });
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "opencode") {
  home.packages = [ opencode-desktop ];

  dotfiles.nixpkgsWatch.opencode-desktop = {
    inherit (opencode-desktop) version;
    reason = "use pkgs.opencode-desktop in modules/tooling/ai/opencode-desktop.nix and drop the opencode input with its build overrides";
  };
}
