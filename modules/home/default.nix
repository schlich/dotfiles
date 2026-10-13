# The home every Home Manager host gets; desktop pieces (files.nix,
# packages.nix, services.nix) come from den/aspects/users/terminal.nix.
{ ... }:

{
  imports = [
    ./nix.nix
    ./retired-files.nix
    ./session.nix
  ];
}
