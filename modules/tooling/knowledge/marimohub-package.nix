{ lib, pkgs }:

# marimohub publishes its server as a Node single-executable application
# (`marimohub-linux-x64`) on each GitHub release; nixpkgs does not package it.
# The binary unpacks its JavaScript bundle into a per-build cache directory
# (MARIMOHUB_SEA_CACHE_DIR) and imports it, so only the ELF interpreter and
# library path need patching. Bump `version` and `hash` together.
pkgs.stdenv.mkDerivation (finalAttrs: {
  pname = "marimohub";
  version = "0.4.14";

  src = pkgs.fetchurl {
    url = "https://github.com/marimo-team/marimohub/releases/download/v${finalAttrs.version}/marimohub-linux-x64";
    hash = "sha256-cP4gN8LC1GimDJASlbuN4THpeKs8Oouo7SvMY6Pu4nE=";
  };

  dontUnpack = true;
  # Stripping would discard the appended SEA blob.
  dontStrip = true;

  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/bin/marimohub
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/marimohub --version | grep -F ${finalAttrs.version}
  '';

  meta = {
    description = "Self-hostable hub for storing, managing, and running marimo notebooks";
    homepage = "https://github.com/marimo-team/marimohub";
    license = lib.licenses.asl20;
    mainProgram = "marimohub";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
