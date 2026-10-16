{ inputs }:

{
  archify = "${inputs.archify}/archify";
  autoresearch = "${inputs.autoresearch}/.agents/skills/autoresearch";
  marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
  bash-feedback = ../../../.agents/skills/bash-feedback;
  ci = inputs.ci.lib.skills.ci;
  datastar = ../../../.agents/skills/datastar;
  jj = ../../../.agents/skills/jj;
  nushell = ../../../.agents/skills/nushell;
  nushell-plugin-builder = ../../../.agents/skills/nushell/plugin-builder;
  nushell-text-processing = ../../../.agents/skills/nushell/text-processing;
  rlm = ../../../.agents/skills/rlm;
  typesafe-ai = "${inputs.typesafe-skills}/skills/typesafe-ai";
  modern-web-guidance = "${inputs.modern-web-guidance}/skills/modern-web-guidance";
}
# Effective HTML's skills link to each other as siblings (../NAME/SKILL.md),
# so each keeps its upstream directory name.
// inputs.nixpkgs.lib.genAttrs [
  "html"
  "big-pics-little-words"
  "design-artifact"
  "html-wireframe"
  "html-prototype"
  "html-plan"
  "html-diagram"
] (name: "${inputs.effective-html}/skills/${name}")
# Antithesis's skills for setting up, launching, and triaging Antithesis runs.
// inputs.nixpkgs.lib.genAttrs [
  "antithesis-debug"
  "antithesis-documentation"
  "antithesis-feature-workload"
  "antithesis-launch"
  "antithesis-mutation-testing"
  "antithesis-research"
  "antithesis-review-inputs"
  "antithesis-setup"
  "antithesis-setup-k8s"
  "antithesis-skills-feedback"
  "antithesis-triage"
  "antithesis-workload"
] (name: "${inputs.antithesis-skills}/${name}")
# Hegel's skills for writing and reviewing property-based tests.
// inputs.nixpkgs.lib.genAttrs [
  "hegel"
  "hegel-review"
] (name: "${inputs.hegel-skill}/skills/${name}")
