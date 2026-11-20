{ ... }:

{
  users.users.schlich = {
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ];
  };
  virtualisation.docker.enable = true;
}
