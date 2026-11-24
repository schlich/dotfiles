{
  inputs,
  lib,
  pkgs,
}:

# nixpkgs has no taskers. Repackage the upstream v0.7.0 Linux release bundle
# for the Rust binaries and runtime assets, but rebuild its vendored Ghostty
# GTK bridge with `-Dcpu=baseline`: the v0.7.0 release artifact was compiled
# for the packager's host CPU and crashes with SIGILL on Ryzen CPUs without
# those instructions (fixed upstream after v0.7.0 in OneNoted/taskers#13).
let
  version = (lib.importTOML "${inputs.taskers}/Cargo.toml").workspace.package.version;

  ghosttySrc = "${inputs.taskers}/vendor/ghostty";
  ghosttyDeps = pkgs.callPackage "${ghosttySrc}/build.zig.zon.nix" {
    name = "taskers-ghostty-cache-${version}";
  };
  ghosttyBridge = pkgs.stdenv.mkDerivation {
    pname = "taskers-ghostty-bridge";
    inherit version;
    src = ghosttySrc;

    nativeBuildInputs = [
      pkgs.blueprint-compiler
      pkgs.gettext
      pkgs.gitMinimal
      pkgs.gobject-introspection
      pkgs.libxml2
      pkgs.ncurses
      pkgs.pkg-config
      pkgs.zig_0_15
    ];

    buildInputs = import "${ghosttySrc}/nix/build-support/build-inputs.nix" {
      inherit pkgs lib;
      inherit (pkgs) stdenv;
      enableX11 = true;
      enableWayland = false;
    };

    GI_TYPELIB_PATH = import "${ghosttySrc}/nix/build-support/gi-typelib-path.nix" {
      inherit pkgs lib;
      inherit (pkgs) stdenv;
    };

    dontConfigure = true;
    dontUseZigBuild = true;
    dontUseZigInstall = true;

    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
      zig build taskers-bridge \
        --system ${ghosttyDeps} \
        -Dapp-runtime=gtk \
        -Demit-exe=false \
        -Dgtk-wayland=false \
        -Dstrip=true \
        -Di18n=false \
        -Dcpu=baseline \
        -Doptimize=ReleaseFast \
        -Dversion-string=1.3.0 \
        --summary none \
        --prefix "$out"
      runHook postBuild
    '';

    dontInstall = true;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "taskers";
  inherit version;

  src = pkgs.fetchurl {
    url = "https://github.com/OneNoted/taskers/releases/download/v${version}/taskers-linux-bundle-v${version}-x86_64-unknown-linux-gnu.tar.xz";
    hash = "sha256-WfX6DVYSC2WUcxUtRHyNaoZkaEviVyzeq0/KcyLQ2Pw=";
  };

  sourceRoot = ".";
  dontStrip = true;
  dontWrapGApps = true;

  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.wrapGAppsHook4
    pkgs.makeWrapper
  ];

  buildInputs = [
    pkgs.adwaita-icon-theme
    pkgs.cairo
    pkgs.glib
    pkgs.glib-networking
    pkgs.graphene
    pkgs.gsettings-desktop-schemas
    pkgs.gtk4
    pkgs.hicolor-icon-theme
    pkgs.libadwaita
    pkgs.libx11
    pkgs.stdenv.cc.cc.lib
    pkgs.webkitgtk_6_0
    pkgs.xz
  ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/taskers" "$out/bin"
    cp -r bin ghostty terminfo "$out/libexec/taskers/"
    install -Dm755 "${ghosttyBridge}/lib/libtaskers_ghostty_bridge.so" \
      "$out/libexec/taskers/ghostty/lib/libtaskers_ghostty_bridge.so"
    chmod +x "$out/libexec/taskers/bin/"*

    substitute "${inputs.taskers}/assets/taskers.desktop.in" dev.taskers.app.desktop \
      --replace-fail '{{EXEC}}' 'taskers'
    install -Dm644 dev.taskers.app.desktop \
      "$out/share/applications/dev.taskers.app.desktop"
    install -Dm644 "${inputs.taskers}/assets/taskers.svg" \
      "$out/share/icons/hicolor/scalable/apps/taskers.svg"
    install -Dm644 "${inputs.taskers}/LICENSE" \
      "$out/share/licenses/taskers/LICENSE"

    runHook postInstall
  '';

  postFixup = ''
    makeWrapper "$out/libexec/taskers/bin/taskers" "$out/bin/taskers" \
      "''${gappsWrapperArgs[@]}" \
      --set TASKERS_CTL_PATH "$out/bin/taskersctl" \
      --set TASKERS_GHOSTTY_RUNTIME_DIR "$out/libexec/taskers/ghostty" \
      --set GHOSTTY_RESOURCES_DIR "$out/libexec/taskers/ghostty" \
      --set TERMINFO "$out/libexec/taskers/terminfo" \
      --set TASKERS_DISABLE_GHOSTTY_RUNTIME_BOOTSTRAP 1

    makeWrapper "$out/libexec/taskers/bin/taskers-terminald" "$out/bin/taskers-terminald" \
      --set TASKERS_GHOSTTY_RUNTIME_DIR "$out/libexec/taskers/ghostty" \
      --set GHOSTTY_RESOURCES_DIR "$out/libexec/taskers/ghostty" \
      --set TERMINFO "$out/libexec/taskers/terminfo" \
      --set TASKERS_DISABLE_GHOSTTY_RUNTIME_BOOTSTRAP 1

    makeWrapper "$out/libexec/taskers/bin/taskersctl" "$out/bin/taskersctl"
  '';

  meta = {
    description = "Agent-first Linux terminal workspace with tiling panes, attention rail, and control CLI";
    homepage = "https://github.com/OneNoted/taskers";
    changelog = "https://github.com/OneNoted/taskers/releases/tag/v${version}";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "taskers";
    platforms = [ "x86_64-linux" ];
  };
}
