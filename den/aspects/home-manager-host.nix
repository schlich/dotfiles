{ inputs, ... }:
{
  # Hosts with a Home Manager user, whatever their role: Den imports the
  # Home Manager NixOS module only there, so its settings live here too.
  den.schema.hm-host.includes = [
    {
      nixos = {
        # Starship's jj module (modules/programs/shell.nix) runs jj-starship,
        # and the home's Nushell commands use writeNuScriptBin.
        nixpkgs.overlays = [
          inputs.jj-starship.overlays.default
          inputs.nushellWith.overlays.default
        ];
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "hm-backup";
          extraSpecialArgs = { inherit inputs; };
        };
      };
    }
  ];
}
