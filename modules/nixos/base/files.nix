{ ... }:

let
  repository = "/home/schlich/dotfiles";
in
{
  environment.etc."nixos/flake.nix" = {
    source = "${repository}/flake.nix";
    mode = "direct-symlink";
  };
}
