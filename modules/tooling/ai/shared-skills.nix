{ inputs }:

{
  archify = "${inputs.archify}/archify";
  autoresearch = "${inputs.autoresearch}/.agents/skills/autoresearch";
  marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
  bash-feedback = ../../../.agents/skills/bash-feedback;
  ci = inputs.ci.lib.skills.ci;
  datastar = ../../../.agents/skills/datastar;
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
