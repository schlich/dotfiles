{ pkgs, ... }:

{
  # The knowledge base lives in its own JJ repository at
  # dotfiles.paths.kb (~/Research/kb). Its
  # .iwe/config.toml, schemas, and MEMORY.md policy belong to that repository:
  # `iwe claude enable` and `/iwe:reflect` rewrite them at runtime.
  home.packages = [ pkgs.iwe ];

  # Defined here and assigned to markdown only by the knowledge base's
  # .helix/languages.toml,
  # so other repositories' markdown keeps marksman alone.
  programs.helix.languages.language-server.iwe.command = "${pkgs.iwe}/bin/iwes";

  programs.nushell.extraConfig = ''
    use ${../../../nushell/kb.nu} *
  '';
}
