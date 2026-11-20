{
  description = "Honeycomb input group: skills for web pages and diagrams";

  inputs = {
    archify = {
      url = "github:tt-a1i/archify";
      flake = false;
    };
    effective-html = {
      url = "github:plannotator/effective-html";
      flake = false;
    };
    modern-web-guidance = {
      url = "github:GoogleChrome/modern-web-guidance";
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
