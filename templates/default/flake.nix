{
  description = "A new project";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    nushellWith = {
      url = "github:YPares/nushellWith/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { nixpkgs, nushellWith, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nushellWith.overlays.default ];
      };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          bat
          difftastic
          fd
          gh
          jujutsu
          nil
          nixd
          nixfmt-tree
          nushell
          prek
          ripgrep
        ];
      };

      formatter.${system} = pkgs.nixfmt-tree;

      checks.${system}.dev-shell = pkgs.runCommand "dev-shell-check" { } ''
        test -x ${pkgs.nushell}/bin/nu
        test -x ${pkgs.jujutsu}/bin/jj
        touch "$out"
      '';
    };
}
