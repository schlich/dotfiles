{
  description = "Honeycomb input group: version control and its forges";

  inputs = {
    # The `ci` trunk workflow with its companions and `ci tower`, fetched
    # from GitHub. Every workspace runs the version this lock pins;
    # `nix-suite update ci` moves to a newer one.
    ci.url = "github:schlich/ci";
    # jj-graph, whose jj-normalize plans, checks, and normalizes change
    # graphs; jj runs it as `jj normalize`.
    jj-graph.url = "github:schlich/jj-graph";
    # Built from its own lock file, without its flake's separate nixpkgs; bump
    # the tag to update jj-hunk.
    jj-hunk = {
      url = "github:laulauland/jj-hunk/v0.5.1";
      flake = false;
    };
    gh-stack = {
      url = "github:github/gh-stack";
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
