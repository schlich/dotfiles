{
  description = "Honeycomb input group: coding agents and what they read";

  inputs = {
    clients.url = "path:./clients";
    knowledge.url = "path:./knowledge";
    skills.url = "path:./skills";
    fieldnotes.url = "github:schlich/fieldnotes";
  };

  # `sources` are this group's inputs, with those of the groups inside it,
  # by name; `paths` say where each sits, as `nix flake update` names it.
  outputs =
    inputs:
    let
      own = removeAttrs inputs [
        "self"
        "clients"
        "knowledge"
        "skills"
      ];
      nested = group: builtins.mapAttrs (_: path: "${group}/${path}") inputs.${group}.paths;
    in
    {
      sources = own // inputs.clients.sources // inputs.knowledge.sources // inputs.skills.sources;
      paths =
        builtins.mapAttrs (name: _: name) own // nested "clients" // nested "knowledge" // nested "skills";
    };
}
