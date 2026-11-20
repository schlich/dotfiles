{
  lib,
  pkgs,
}:

# nixpkgs dropped Dagger after 0.8.8, and the dagger/nix flake publishes only
# stable releases, so take the 1.0 beta's release binary. It is a static Go
# build and needs no patching.
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "dagger";
  version = "1.0.0-beta.21";

  src = pkgs.fetchurl {
    url = "https://dl.dagger.io/dagger/releases/${finalAttrs.version}/dagger_v${finalAttrs.version}_linux_amd64.tar.gz";
    hash = "sha256-xax3elyZCJhpZglDOBE24iF3tZpGQS4xDC/vWUdgoEE=";
  };

  sourceRoot = ".";

  nativeBuildInputs = [ pkgs.installShellFiles ];

  installPhase = ''
    runHook preInstall
    install -Dm755 dagger "$out/bin/dagger"
    runHook postInstall
  '';

  postInstall = ''
    installShellCompletion --cmd dagger \
      --bash <("$out/bin/dagger" completion bash) \
      --fish <("$out/bin/dagger" completion fish) \
      --zsh <("$out/bin/dagger" completion zsh)
  '';

  meta = {
    description = "CI engine that runs checks as containerized, cached functions";
    homepage = "https://dagger.io";
    changelog = "https://github.com/dagger/dagger/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    mainProgram = "dagger";
    platforms = [ "x86_64-linux" ];
  };
})
