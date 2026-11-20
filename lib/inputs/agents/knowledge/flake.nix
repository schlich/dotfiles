{
  description = "Honeycomb input group: the knowledge base";

  inputs = {
    # No flake upstream; bump the tag to update IWE.
    iwe = {
      url = "github:iwe-org/iwe/iwe-v0.24.2";
      flake = false;
    };
    iwe-skills = {
      url = "github:iwe-org/skills";
      flake = false;
    };
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
