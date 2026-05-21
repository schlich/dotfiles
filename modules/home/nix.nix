{ pkgs, ... }:

{
  nix.package = pkgs.nix;
  nixpkgs.config.allowUnfree = true;

  age.secrets.github-token.file = ../../secrets/github-token.age;
}
