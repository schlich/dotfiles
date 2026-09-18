{ username, ... }:

{
  users.users.${username} = {
    extraGroups = [
      "wheel"
      "networkmanager"
      "docker"
    ];
  };
  virtualisation.docker.enable = true;
}
