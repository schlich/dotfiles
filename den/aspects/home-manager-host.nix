{ inputs, lib, ... }:
{
  # Hosts with a standalone Home Manager user (`home = true` in
  # den/inventory.nix), whatever their role. Each home builds from its host's
  # package set, so the overlays its modules need go on the host: Starship's
  # jj module (modules/programs/shell.nix) runs jj-starship, and the home's
  # Nushell commands use writeNuScriptBin.
  den.schema.host.includes = [
    (
      { host, ... }:
      lib.optionalAttrs (lib.any (user: user.home) (lib.attrValues host.users)) {
        nixos.nixpkgs.overlays = [
          inputs.jj-starship.overlays.default
          inputs.nushellWith.overlays.default
        ];
      }
    )
  ];
}
