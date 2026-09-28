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
      # homelab's sudo accepts this key from the forwarded agent. Forward it
      # only here: root on the far end can use the agent while connected.
      homelab = {
        IdentityFile = [ "/home/schlich/.ssh/id_ed25519_tangled" ];
        IdentitiesOnly = true;
        ForwardAgent = true;
      };
    };
  };
}
