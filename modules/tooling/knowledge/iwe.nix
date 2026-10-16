{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  iwe = import ./iwe-package.nix { inherit inputs lib pkgs; };
in
{
  # The knowledge base lives in its own JJ repository at ~/kb. Its
  # .iwe/config.toml, schemas, and MEMORY.md policy belong to that repository:
  # `iwe claude enable` and `/iwe:reflect` rewrite them at runtime.
  home.packages = [ iwe ];

  dotfiles.nixpkgsWatch.iwe = {
    inherit (iwe) version;
    reason = "replace modules/tooling/knowledge/iwe-package.nix with pkgs.iwe where iwe.nix, tooling/ai/common.nix and flake.nix import it, and drop the iwe input";
  };

  # Defined here and assigned to markdown only by ~/kb/.helix/languages.toml,
  # so other repositories' markdown keeps marksman alone.
  programs.helix.languages.language-server.iwe.command = "${iwe}/bin/iwes";

  programs.nushell.extraConfig = ''
    use ${../../../nushell/kb.nu} *
  '';
}
