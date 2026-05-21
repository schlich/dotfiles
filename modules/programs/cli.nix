{ ... }:

{
  programs.home-manager.enable = true;
  programs.htop.enable = true;

  programs.nix-search-tv = {
    enable = true;
    enableTelevisionIntegration = true;
  };

  programs.tealdeer = {
    enable = true;
    settings.updates.auto_update = true;
  };
}
