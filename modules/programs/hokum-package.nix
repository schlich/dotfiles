{
  lib,
  pkgs,
}:

# nixpkgs has no Hokum and upstream ships no flake, only prebuilt binaries.
# Build the tag from source; bump `version` and both hashes to update it.
pkgs.rustPlatform.buildRustPackage rec {
  pname = "hokum";
  version = "0.1.3";

  src = pkgs.fetchFromGitHub {
    owner = "anomalyco";
    repo = "hokum";
    tag = "v${version}";
    hash = "sha256-+CS6Rq3lQsli+F7GR56vejJfkHFWRI+dJV7AnWkMs60=";
  };

  # Rune, its UI framework, comes from a git revision of anomalyco/rune.
  cargoHash = "sha256-r3vn64VQ0CezL+j8VUckrdNkhPxPs4Z9Q/J0jOtqNLo=";

  nativeBuildInputs = [
    pkgs.pkg-config
    pkgs.rustPlatform.bindgenHook
  ];
  buildInputs = [
    pkgs.libxkbcommon
    pkgs.pipewire
  ];

  # Rune loads Vulkan and the Wayland client library at run time.
  postFixup = ''
    patchelf --add-rpath ${
      lib.makeLibraryPath [
        pkgs.vulkan-loader
        pkgs.wayland
        pkgs.libxkbcommon
      ]
    } $out/bin/hokum
  '';

  postInstall = ''
    install -Dm644 packaging/hokum.desktop -t $out/share/applications
    install -Dm644 packaging/app.hokum.Notifications.service -t $out/share/dbus-1/services
    substituteInPlace $out/share/dbus-1/services/app.hokum.Notifications.service \
      --replace-fail /usr/bin/hokum $out/bin/hokum
  '';

  meta = {
    description = "Wayland control center: notification daemon, sound and Bluetooth";
    homepage = "https://hokum.app";
    license = lib.licenses.mit;
    mainProgram = "hokum";
    platforms = [ "x86_64-linux" ];
  };
}
