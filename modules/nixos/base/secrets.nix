{ inputs, ... }:

# The secrets mechanism for hosts whose inventory sets profile.secrets. The
# modules that need a secret declare it under age.secrets, and
# secrets/secrets.nix lists the host's key among that file's recipients:
# agenix decrypts at activation, and a file the host cannot decrypt fails the
# switch. agenix stays off on a host with no secret declared.
{
  imports = [ inputs.agenix.nixosModules.default ];

  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
}
