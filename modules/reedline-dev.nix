{ inputs, ... }:
{
  perSystem = { config, self', inputs', pkgs, system, ... }: {
    devShells.reedline = pkgs.mkShell {
      name = "reedline-dev";

      buildInputs = with pkgs; [
        # Rust toolchain
        rustc
        cargo
        rustfmt
        clippy
        rust-analyzer

        # Build dependencies
        pkg-config

        # Development tools
        git
      ];

      shellHook = ''
        echo "Reedline development environment"
        echo "Rust version: $(rustc --version)"
        echo "Cargo version: $(cargo --version)"
        echo ""
        echo "To clone reedline: git clone https://github.com/nushell/reedline"
        echo "Then: cd reedline && cargo build"
      '';
    };
  };
}
