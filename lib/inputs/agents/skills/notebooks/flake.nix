{
  description = "Honeycomb input group: skills for notebooks";

  inputs = {
    marimo-pair = {
      url = "github:marimo-team/marimo-pair";
      flake = false;
    };
    marimo-skills = {
      url = "github:marimo-team/skills";
      flake = false;
    };
    # Bayesian workflow, amortized inference, and causal inference skills (PyMC,
    # BayesFlow)
    baygent-skills = {
      url = "github:Learning-Bayesian-Statistics/baygent-skills";
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
