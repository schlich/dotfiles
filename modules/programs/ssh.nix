{ lib, pkgs, ... }:

{
  # ssh, scp and sftp come from the user profile, ahead of the system's
  # OpenSSH on PATH, with their configuration on the wrapper.
  home.packages = [ (import ./ssh-client.nix { inherit lib pkgs; }) ];
  dotfiles.retiredHomeFiles = [ ".ssh/config" ];
}
