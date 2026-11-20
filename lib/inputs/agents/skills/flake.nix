{
  description = "Honeycomb input group: agent skills, by subject";

  inputs = {
    testing.url = "path:./testing";
    web.url = "path:./web";
    notebooks.url = "path:./notebooks";
    practice.url = "path:./practice";
    jev.url = "path:./jev";
    meta-quest-agentic-tools = {
      url = "github:meta-quest/agentic-tools";
      flake = false;
    };
  };

  # `sources` are this group's inputs, with those of the groups inside it,
  # by name; `paths` say where each sits, as `nix flake update` names it.
  outputs =
    inputs:
    let
      own = removeAttrs inputs [
        "self"
        "testing"
        "web"
        "notebooks"
        "practice"
        "jev"
      ];
      nested = group: builtins.mapAttrs (_: path: "${group}/${path}") inputs.${group}.paths;
    in
    {
      sources =
        own
        // inputs.testing.sources
        // inputs.web.sources
        // inputs.notebooks.sources
        // inputs.practice.sources
        // inputs.jev.sources;
      paths =
        builtins.mapAttrs (name: _: name) own
        // nested "testing"
        // nested "web"
        // nested "notebooks"
        // nested "practice"
        // nested "jev";
    };
}
