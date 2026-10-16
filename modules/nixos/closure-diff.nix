{ lib, pkgs, ... }:

let
  closureDiff = import ../../lib/closure-diff.nix { inherit lib pkgs; };
in
{
  environment.systemPackages = [ closureDiff ];

  # Every activation prints which packages and versions change, however it
  # was started: system-switch's nixos-switch-main unit (whose journal
  # system-switch prints), Colmena, or nixos-rebuild. Activation runs before
  # /run/current-system moves, so that link is still the outgoing system. At
  # boot the link does not exist yet, and an unchanged system prints nothing.
  # dry-activate skips it: its preview is the service changes, and the switch
  # that follows prints this once. A failed diff never fails the activation.
  system.activationScripts.closure-diff = {
    supportsDryActivation = false;
    text = ''
      if [ -e /run/current-system ] \
        && [ "$(readlink -f /run/current-system)" != "$(readlink -f "$systemConfig")" ]; then
        echo "package changes from the running system:"
        ${lib.getExe closureDiff} /run/current-system "$systemConfig" || true
      fi
    '';
  };
}
