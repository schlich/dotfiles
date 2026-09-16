{ ... }:

{
  programs.ssh = {
    enable = true;
    addKeysToAgent = "yes";
    matchBlocks = {
      "tangled.org" = {
        hostname = "tangled.org";
        user = "git";
        identityFile = [ "~/.ssh/id_ed25519" ];
        identitiesOnly = true;
      };
    };
  };
}
