{
  description = "Honeycomb input group: the shell, version control and the multiplexer";

  inputs = {
    shell.url = "path:./shell";
    vcs.url = "path:./vcs";
    # Mission control TUI for AI coding agents; not in nixpkgs.
    luvus.url = "github:RizRiyz/luvus";
  };

  # `sources` are this group's inputs, with those of the groups inside it,
  # by name; `paths` say where each sits, as `nix flake update` names it.
  outputs =
    inputs:
    let
      own = removeAttrs inputs [
        "self"
        "shell"
        "vcs"
      ];
      nested = group: builtins.mapAttrs (_: path: "${group}/${path}") inputs.${group}.paths;
    in
    {
      sources = own // inputs.shell.sources // inputs.vcs.sources;
      paths = builtins.mapAttrs (name: _: name) own // nested "shell" // nested "vcs";
    };
}
