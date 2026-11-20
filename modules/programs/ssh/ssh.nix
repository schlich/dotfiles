{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Rex's ssh guard (tooling/terminals/rex.nix) makes ssh from a Rex terminal send
  # TERM=xterm-256color to hosts without the xterm-rex entry. Home Manager's
  # programs.ssh would carry it, but this config lives on the wrapper instead.
  rex = lib.attrByPath [ "programs" "rex" ] { enable = false; } config;
in
{
  # ssh, scp and sftp come from the user profile, ahead of the system's
  # OpenSSH on PATH, with their configuration on the wrapper.
  home.packages = [
    (import ./ssh-client.nix {
      inherit lib pkgs;
      includes = lib.optional (
        rex.enable && rex.package != null
      ) "${rex.package}/share/rex/ssh_config.d/50-rex.conf";
    })
  ];
  dotfiles.retiredHomeFiles = [ ".ssh/config" ];
}
