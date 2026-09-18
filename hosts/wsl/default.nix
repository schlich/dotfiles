{
  homeDirectory,
  pkgs,
  stateVersion,
  username,
  ...
}:

{
  wsl.enable = true;
  wsl.defaultUser = username;
  wsl.docker-desktop.enable = true;

  networking.hostName = "evilcorp";
  system.stateVersion = stateVersion;

  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    optimise = {
      automatic = true;
      dates = [ "weekly" ];
    };
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      trusted-users = [ username ];
    };
  };
  nixpkgs.config.allowUnfree = true;

  users.defaultUserShell = pkgs.nushell;
  users.users.${username} = {
    uid = 1001;
    home = homeDirectory;
    shell = pkgs.nushell;
    isNormalUser = true;
    extraGroups = [
      "wheel"
    ];
  };
  environment.shells = [ pkgs.nushell ];

  # The ChatGPT desktop app checks for the conventional Linux Bash path when
  # it launches Codex inside WSL. NixOS keeps Bash in the Nix store instead.
  systemd.tmpfiles.rules = [
    "L+ /usr/bin/bash - - - - ${pkgs.bash}/bin/bash"
  ];

  time.timeZone = "America/Chicago";
  i18n.defaultLocale = "en_US.UTF-8";
}
