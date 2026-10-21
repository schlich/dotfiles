{
  # Trust devenv's binary cache, which every `devenv` run asks for. The daemon
  # honors that request only from a trusted user or for a trusted substituter,
  # so listing it here lets any user's devenv fetch its prebuilt closures.
  nix.settings = {
    trusted-substituters = [ "https://devenv.cachix.org" ];
    trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };
}
