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
    inputs.yazelix.homeManagerModules.default
    ./modules/home
    ./modules/programs
  ];

  manual.manpages.enable = false;
  home = {
    inherit username homeDirectory stateVersion;
  };
}
