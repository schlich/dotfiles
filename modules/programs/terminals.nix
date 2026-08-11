{ ... }:

{
  programs.rio.enable = true;
  programs.ghostty.enable = true;
  programs.ghostty.installBatSyntax = true;
  programs.kitty = {
    enable = true;
    enableGitIntegration = true;
    font.name = "Monaspace Krypton";
  };
}
