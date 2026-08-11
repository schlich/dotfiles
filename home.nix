{
  inputs,
  username,
  homeDirectory,
  stateVersion ? "26.05",
  ...
}:
{
  imports = [
    inputs.ragenix.homeManagerModules.default
    inputs.noctalia.homeModules.default
    ./modules/tooling/interface.nix
    ./modules/home
    ./modules/programs
  ];

  manual.manpages.enable = false;
  home = {
    inherit username homeDirectory stateVersion;
  };
}
