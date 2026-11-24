{
  inputs,
  lib,
  pkgs,
}:

# nixpkgs has no webterm. Build the pinned tag from its committed frontend
# bundle (webterm/static/js/terminal.js and ghostty-vt.wasm) and Go modules.
let
  version = lib.strings.trim (builtins.readFile "${inputs.webterm}/VERSION");
in
pkgs.buildGoModule {
  pname = "webterm";
  inherit version;
  src = inputs.webterm;

  vendorHash = "sha256-nUhH4OKfCVyfS10Q2jJFeTpK/qgYINkLlb/hxfzIlXs=";

  subPackages = [ "cmd/webterm" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/rcarmo/webterm/webterm.Version=${version}"
  ];

  meta = {
    description = "Web terminal server with session dashboard and Ghostty WASM frontend";
    homepage = "https://github.com/rcarmo/webterm";
    changelog = "https://github.com/rcarmo/webterm/releases/tag/v${version}";
    license = lib.licenses.mit;
    mainProgram = "webterm";
    platforms = [ "x86_64-linux" ];
  };
}
