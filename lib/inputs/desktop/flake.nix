{
  description = "Honeycomb input group: the graphical session";

  inputs = {
    niri.url = "github:epireyn/niri-flake";
    # Noctalia Minimizer: reversible window minimization for Niri (Noctalia
    # Shell plugin)
    noc-minimizer.url = "github:SwashX-dev/Noc-minimizer";
    # Hokum, the notification daemon, which nixpkgs lacks. Its flake is on the
    # default branch only; v0.1.3 predates it.
    hokum.url = "github:anomalyco/hokum";
    dicta.url = "github:schlich/dicta";
    # Local dictation (Linux beta); not in nixpkgs.
    hex.url = "github:anomalyco/hex";
    ai-usagebar.url = "github:akitaonrails/ai-usagebar";
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
