# Each host's key for logging in as schlich, which OpenSSH on every host
# accepts. Only the public keys are stored in the repository.
{
  # ~/.ssh/id_ed25519_tangled, which also signs in to Tangled.
  asus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINJRdPuDm1hX5iOgHNl63aUVPIUvkMhAFlBaoxOiSPEA schlich@tangled";
  homelab = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG129BCzPow4ILpwLDY48F446oDilNjw4p/xy8HzJ8Um schlich@homelab";
}
