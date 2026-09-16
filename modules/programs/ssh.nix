{ ... }:

{
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    settings = {
      "*" = {
        AddKeysToAgent = "yes";
      };
      "tangled.org" = {
        HostName = "tangled.org";
        User = "git";
        IdentityFile = [ "/home/schlich/.ssh/id_ed25519_tangled" ];
        IdentitiesOnly = true;
        AddressFamily = "inet";
      };
    };
  };
}
