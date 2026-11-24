{
  inputs,
  lib,
  pkgs,
}:

# nu_plugin_ghostty: programs run in terminals kept in libghostty-vt, driven
# from Nushell and read back as HTML rows. nixpkgs has no package for it, and
# upstream builds only on macOS: build.sh links libghostty-vt's XCFramework.
# This runs build.sh's two zig commands against the libghostty-vt 1.0.1 built
# here (./libghostty-vt), with Linux's header for forkpty.
let
  src = inputs.nu-plugin-ghostty;
  libghosttyVt = pkgs.callPackage ./libghostty-vt/package.nix { };
  date = src.lastModifiedDate;
in
pkgs.stdenv.mkDerivation {
  pname = "nu-plugin-ghostty";
  # main.zig's plugin_version, at the locked commit's date.
  version = "0.1.0-unstable-${lib.substring 0 4 date}-${lib.substring 4 2 date}-${lib.substring 6 2 date}";
  inherit src;

  nativeBuildInputs = [ pkgs.zig_0_17 ];

  # macOS declares forkpty in util.h, glibc in pty.h.
  postPatch = ''
    substituteInPlace cdeps.h --replace-fail '#include <util.h>' '#include <pty.h>'
  '';

  dontConfigure = true;

  # Zig 0.17 has no @cImport, so the C headers become c.zig first. The plugin
  # links libghostty-vt's static archive, as upstream does, and gets the
  # stdenv's dynamic linker instead of the FHS path Zig assumes.
  buildPhase = ''
    runHook preBuild
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global" ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local"
    zig translate-c -lc -I ${libghosttyVt.dev}/include cdeps.h > c.zig
    zig build-exe main.zig -lc ${libghosttyVt.dev}/lib/libghostty-vt.a \
      -O ReleaseSafe -mcpu baseline \
      --dynamic-linker "$(cat "$NIX_CC/nix-support/dynamic-linker")" \
      -femit-bin=nu_plugin_ghostty
    runHook postBuild
  '';

  # The page side (<ghostty-term> and its fonts) and the http-nu demos go
  # with the plugin, for pages that project its terminals.
  installPhase = ''
    runHook preInstall
    install -Dm755 nu_plugin_ghostty "$out/bin/nu_plugin_ghostty"
    mkdir -p "$out/share/nu_plugin_ghostty"
    cp -r static demo "$out/share/nu_plugin_ghostty/"
    runHook postInstall
  '';

  # Load the plugin into this Nushell, run a program in one of its
  # terminals, and read the program's output back from the terminal's rows.
  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.nushell ];
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    nu --no-config-file --plugins "[$out/bin/nu_plugin_ghostty]" --commands '
      let t = (ghostty spawn [echo "hello from libghostty"] --cols 40 --rows 5)
      mut tries = 0
      while ($t | ghostty info).alive and $tries < 200 { sleep 50ms; $tries += 1 }
      let text = ($t | ghostty window 0 5 | get html | str replace --all --regex "<[^>]*>" "")
      $t | ghostty close
      if not ($text =~ "hello from libghostty") {
        error make { msg: $"the terminal shows no output: ($text)" }
      }
      print "nu_plugin_ghostty read its terminal back"
    '
    runHook postInstallCheck
  '';

  meta = {
    description = "Nushell plugin that runs programs in libghostty-vt terminals and reads them back as HTML";
    homepage = "https://github.com/cablehead/nu_plugin_ghostty";
    license = lib.licenses.mit;
    mainProgram = "nu_plugin_ghostty";
    platforms = [ "x86_64-linux" ];
  };
}
