{
  description = "Honeycomb input group: skills for testing";

  inputs = {
    antithesis-skills = {
      # Pinned before 2026-11-12, when upstream moved its core skills
      # (setup, workload, launch, triage, debug, ...) to
      # github:antithesishq/antithesis-plugin. Unpin once
      # modules/tooling/ai/shared/shared-skills.nix takes them from the plugin.
      url = "github:antithesishq/antithesis-skills/4ee2746a46703185dc5cf6864cb1961db74d28eb";
      flake = false;
    };
    hegel-skill = {
      url = "github:hegeldev/hegel-skill";
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
