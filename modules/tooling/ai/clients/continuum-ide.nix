{ inputs, pkgs, ... }:

# Continuum IDE, the user's fork of T3 Code (SwashX-dev/continuum-ide), built
# by that repository's own flake. Its binaries are `continuum-ide` (desktop)
# and `continuum` (server CLI), so it installs beside T3 Code. Its Wayland app
# ID is io.github.swashxdev.ContinuumIDE.

{
  home.packages = [
    inputs.continuum-ide.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];
}
