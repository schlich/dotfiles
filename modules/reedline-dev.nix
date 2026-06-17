{ ... }:
{
  perSystem = { pkgs, ... }: {
    devShells.reedline = pkgs.mkShell {
      name = "reedline-dev";

      packages =
        with pkgs;
        [
          cargo-nextest
          clippy
          cargo
          git
          pkg-config
          rust-analyzer
          rustc
          rustfmt
          sqlite
        ]
        ++ lib.optionals stdenv.hostPlatform.isLinux [
          libxkbcommon
          wayland
        ]
        ++ lib.optionals stdenv.hostPlatform.isDarwin [
          darwin.apple_sdk.frameworks.AppKit
        ];

      RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

      shellHook = ''
        echo "Reedline development environment"
        echo "Rust: $(rustc --version)"
        echo "Cargo: $(cargo --version)"
        echo "Nextest: $(cargo nextest --version)"
      '';
    };
  };
}
