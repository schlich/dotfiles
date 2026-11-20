{
  description = "Honeycomb input group: skills for how to work";

  inputs = {
    autoresearch = {
      url = "github:uditgoenka/autoresearch";
      flake = false;
    };
    grill-me = {
      url = "github:udecode/plate";
      flake = false;
    };
    humanlayer-skills = {
      url = "github:humanlayer/skills";
      flake = false;
    };
    mattpocock-skills = {
      url = "github:mattpocock/skills";
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
