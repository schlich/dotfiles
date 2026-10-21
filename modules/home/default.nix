# The home every Home Manager host gets; desktop pieces (files.nix,
# packages.nix, services.nix) come from den/aspects/users/terminal.nix.
{ ... }:

{
  imports = [
    ./ci-trace.nix
    ./nix.nix
    ./nixpkgs-watch.nix
    ./retired-files.nix
    ./session.nix
  ];
}
