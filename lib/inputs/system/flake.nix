{
  description = "Honeycomb input group: what every host is built from";

  inputs = {
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    home-manager.url = "github:nix-community/home-manager";
    den.url = "github:denful/den/v0.18.0";
    # Pushes Den's hosts over ssh (clan below), alongside system-switch,
    # which pulls GitHub's main on the host itself.
    clan-core.url = "https://git.clan.lol/clan/clan-core/archive/main.tar.gz";
    impermanence.url = "github:nix-community/impermanence";
    # Decrypts secrets/*.age at activation on hosts whose inventory sets
    # profile.secrets, with the host's OpenSSH key (secrets/secrets.nix).
    agenix.url = "github:ryantm/agenix";
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
