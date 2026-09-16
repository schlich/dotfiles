{ inputs, pkgs, ... }:

{
  home.packages = with pkgs; [
    (callPackage ./openchamber.nix { })
    lsp-ai
    skills
    inputs.ai-usagebar.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
