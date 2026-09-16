{ ... }:

{
  den.aspects.user-packages-baseline.homeManager.imports = [
    ../../../modules/home/packages/baseline.nix
  ];

  den.aspects.user-packages-development =
    { host, ... }:
    if host.profile.development then
      {
        homeManager.imports = [ ../../../modules/home/packages/development.nix ];
      }
    else
      { };

  den.aspects.user-packages-desktop =
    { host, ... }:
    if host.profile.desktop == "niri" then
      {
        homeManager.imports = [ ../../../modules/home/packages/desktop.nix ];
      }
    else
      { };

  den.aspects.user-packages-ai =
    { host, ... }:
    if host.profile.desktop == "niri" then
      {
        homeManager.imports = [ ../../../modules/home/packages/ai.nix ];
      }
    else
      { };
}
