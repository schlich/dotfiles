rust-flake-init:
    nix flake init -t github:yusdacra/nix-cargo-integration

nix-flake-parts:
    nix flake init -t github:hercules-ci/flake-parts

nix-flake-test:
    nix flake clone gitlab:TECHNOFAB/nixtest?dir=lib

check-system:
    nix flake check /etc/nixos/
