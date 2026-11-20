{
  description = "Honeycomb input group: version control and its forges";

  inputs = {
    # The `ci` trunk workflow with its companions and `ci tower`, hosted on
    # Tangled and fetched from its GitHub mirror. Every workspace runs the
    # version this lock pins; `nix-suite update ci` moves to a newer one.
    ci.url = "github:schlich/ci";
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
    tangled.url = "git+https://tangled.org/@tangled.org/core";
    tangled-dash.url = "github:schlich/tangled-dash";
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
