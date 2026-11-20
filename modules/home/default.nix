# The home every Home Manager host gets; desktop pieces (files.nix,
# packages.nix, services.nix) come from den/aspects/users/terminal.nix.
{ ... }:

{
  imports = [
    ./nix/ci-trace.nix
    ./nix/nix.nix
    ./nix/nixpkgs-watch.nix
    ./session/paths.nix
    ./session/retired-files.nix
    ./session/session.nix
  ];
}
