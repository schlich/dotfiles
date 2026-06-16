let
  # myConfig = import ./configuration.nix;
  nixpkgs = builtins.fetchTarball "https://github.com/nixOS/nixpkgs/archive/25.05.tar.gz";
  pkgs = import nixpkgs { };
in

pkgs.testers.runNixOSTest {
  name = "test-flakes";
  nodes.machine = { config, pkgs, ... }: {
    # imports = [ (import ./configuration.nix) ];
  };
  testScript = { nodes, ... }: ''
    machine.succeed("nix --extra-experimental-features nix-command flake init")
  '';
}
