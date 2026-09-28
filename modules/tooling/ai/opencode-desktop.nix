{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:

let
  upstream = inputs.opencode.packages.${pkgs.stdenv.hostPlatform.system};
  # Upstream's postInstall generates shell completions with
  # `opencode completion`, a 1.x subcommand. The v2 CLI treats `completion`
  # as a project directory, fails to chdir into it, and aborts the build.
  # Upstream also builds the CLI for channel "prod", so the service registers
  # itself in service-prod.json, while the desktop only discovers service.json
  # and times out waiting for its background service. "latest" is the official
  # release channel and keeps the same database.
  opencode = upstream.opencode.overrideAttrs (old: {
    postInstall = "";
    env = old.env // {
      OPENCODE_CHANNEL = "latest";
    };
  });
  # Upstream's nix/electron.nix reads Electron's version from the desktop
  # package.json (44.4.3) but still pins Electron 42.10.1's checksums, so the
  # download fails its hash check. Its older nixpkgs also patches ANGLE
  # libraries that Electron 44 no longer ships. Build Electron with this
  # flake's nixpkgs, whose generic.nix skips that step from 44 on, and the
  # x86_64-linux checksum from Electron's official v44.4.3 SHASUMS256.txt.
  # The assertion fails once upstream moves Electron, which is the cue to drop
  # this override.
  electronVersion =
    (builtins.fromJSON (builtins.readFile "${inputs.opencode}/packages/desktop/package.json"))
    .devDependencies.electron;
  electron =
    assert electronVersion == "44.4.3";
    (pkgs.callPackage "${pkgs.path}/pkgs/development/tools/electron/binary/generic.nix" { })
      electronVersion
      {
        x86_64-linux = "fe880a7e37160cfd4e00193bc4c713ead7a778abfe74860a2d36d86fd0be48a8";
        # Unused by the desktop build, which needs only the binary.
        headers = "sha256-4eUy3BZVvxTl7KUOsxio7769lL6ag/ecbeK+qLURWMI=";
      };
  # OpenCode 2 desktop, which bundles that v2 CLI as its sidecar.
  opencode-desktop =
    (upstream.opencode-desktop.override (old: {
      inherit opencode;
      callPackage =
        fn: args: if baseNameOf fn == "electron.nix" then electron else old.callPackage fn args;
    })).overrideAttrs
      (old: {
        # The desktop's prebuild reads the bundled CLI's version from a
        # package.json beside its binary, which upstream's build never writes.
        buildPhase =
          let
            anchor = "bun run build";
            manifest = builtins.toJSON { inherit (opencode) version; };
            patched =
              builtins.replaceStrings
                [ anchor ]
                [
                  "echo '${manifest}' > \"$OPENCODE_CLI_DIST/$cli_package/package.json\"\n${anchor}"
                ]
                old.buildPhase;
          in
          assert patched != old.buildPhase;
          patched;
      });
in
lib.mkIf (config.dotfiles.alternates || config.dotfiles.primary.desktopAgent == "opencode") {
  home.packages = [ opencode-desktop ];

  xdg.configFile."autostart/opencode-desktop.desktop".source =
    "${opencode-desktop}/share/applications/ai.opencode.desktop.desktop";
}
