{
  config,
  inputs,
  lib,
  ...
}:
let
  embeddedUsers =
    host: lib.filterAttrs (_: user: user.home && user.homeActivation == "embedded") (host.users or { });
in
{
  den.schema.host.includes = [
    # Hosts with a Home Manager user (`home = true` in den/inventory.nix),
    # whatever their role and wherever the home is activated. Each home
    # builds from its host's package set, so the overlays its modules need
    # go on the host: the home's Nushell commands use writeNuScriptBin.
    (
      { host, ... }:
      lib.optionalAttrs (lib.any (user: user.home) (lib.attrValues host.users)) {
        nixos.nixpkgs.overlays = [
          inputs.nushellWith.overlays.default
        ];
      }
    )
    # Hosts whose user's home is embedded (homeActivation = "embedded"): the
    # Home Manager NixOS module activates it with every switch of the system.
    # Den resolves the home exactly as it would a standalone one
    # (den/inventory.nix), and its module list is imported here, so the home
    # is the same either way; only where it is activated differs. Like the
    # standalone home, it builds from the system's package set and sees the
    # system as osConfig. Its packages land in /etc/profiles/per-user/USER,
    # which home.profileDirectory names.
    (
      { host, ... }:
      let
        users = embeddedUsers host;
      in
      lib.optionalAttrs (users != { }) {
        nixos = {
          imports = [ inputs.home-manager.nixosModules.home-manager ];
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit inputs; };
            users = lib.mapAttrs (userName: _: {
              imports = config.flake.embeddedHomes."${userName}@${host.name}".modules;
            }) users;
          };
        };
      }
    )
  ];
}
