{
  lib,
  stdenv,
  callPackage,
  fetchFromGitHub,
  gitMinimal,
  ncurses,
  pkg-config,
  zig_0_17,

  testers,

  optimize ? "ReleaseFast",
  simd ? true,
}:

# libghostty-vt 1.0.1, which nu_plugin_ghostty links. nixpkgs ships
# 0.1.0-unstable-2026-08-06; this is the package from NixOS/nixpkgs#581882,
# which moves it to 1.0.1, without its Darwin parts. Drop this directory once
# nixpkgs ships 1.0.1 (the `libghostty-vt` entry in ../default.nix).
stdenv.mkDerivation (finalAttrs: {
  pname = "libghostty-vt";
  version = "1.0.1";

  src = fetchFromGitHub {
    owner = "ghostty-org";
    repo = "ghostty";
    tag = "vt-${finalAttrs.version}";
    hash = "sha256-3XBFm8yq25P9eCdjLWwVwZ0tedWCN39U1FbjYD8C+w4=";
  };

  # ./deps.nix is "${finalAttrs.src}/deps/packages.nix"
  deps = callPackage ./deps.nix {
    name = "${finalAttrs.pname}-cache-${finalAttrs.version}";
  };

  __structuredAttrs = true;
  strictDeps = true;

  nativeBuildInputs = [
    gitMinimal
    ncurses
    pkg-config
    zig_0_17
  ];

  dontSetZigDefaultFlags = true;

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Dlib-version-string=${finalAttrs.version}"
    "-Dcpu=baseline"
    "-Doptimize=${optimize}"
    "-Dapp-runtime=none"
    "-Demit-lib-vt=true"
    "-Dsimd=${lib.boolToString simd}"
  ];

  doCheck = false;

  outputs = [
    "out"
    "dev"
  ];

  postInstall = ''
    mkdir -p "$dev/lib"
    mv "$out/lib/libghostty-vt.a" "$dev/lib/"
  '';

  postFixup = ''
    substituteInPlace "$dev/lib/pkgconfig/libghostty-vt-static.pc" \
      --replace-fail "$out" "$dev"
    substituteInPlace "$dev/lib/cmake/ghostty-vt/ghostty-vt-config.cmake" \
      --replace-fail \
      'set(_ghostty_vt_shared_libdir "''${_ghostty_vt_libdir}")' \
      'set(_ghostty_vt_shared_libdir "${placeholder "out"}/lib/")'
  '';

  passthru.tests.pkg-config = testers.hasPkgConfigModules {
    package = finalAttrs.finalPackage.dev;
    versionCheck = true;
  };

  meta = {
    description = "Ghostty's VT (terminal sequence) parsing library";
    homepage = "https://ghostty.org/";
    license = lib.licenses.mit;
    pkgConfigModules = [
      "libghostty-vt"
      "libghostty-vt-static"
    ];
    platforms = [ "x86_64-linux" ];
  };
})
