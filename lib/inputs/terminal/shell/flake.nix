{
  description = "Honeycomb input group: the shell and what runs in it";

  inputs = {
    nushellWith.url = "github:YPares/nushellWith/master";
    # Upstream packages Atuin 18.24; nixpkgs still ships 18.23.
    xs.url = "github:cablehead/xs";
    # The `pst` Nushell module (OSC 7501 program status) that ci reports its
    # phases with and the shell imports; the ci input follows it.
    osc7501-nu = {
      url = "github:schlich/osc7501.nu";
      flake = false;
    };
    ptyZZZ = {
      url = "github:cablehead/ptyZZZ";
      flake = false;
    };
    # Rex, the multiplexer for all work (prebuilt, snapshot channel); not in
    # nixpkgs. flake.lock pins the exact release; `nix-suite update rex`
    # moves to the newest snapshot.
    rex.url = "https://pkgs.superlogical.com/rex/nix/snapshot.tar.gz";
  };

  # `sources` are this group's inputs, with those of the groups inside it,
  # by name; `paths` say where each sits, as `nix flake update` names it.
  outputs =
    inputs:
    let
      own = removeAttrs inputs [ "self" ];
    in
    {
      sources = own;
      paths = builtins.mapAttrs (name: _: name) own;
    };
}
