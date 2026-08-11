{ ... }:

{
  services = {
    home-manager.autoUpgrade.useFlake = true;
    gpg-agent = {
      enable = true;
      enableNushellIntegration = true;
    };
    gnome-keyring.enable = true;
  };
}
