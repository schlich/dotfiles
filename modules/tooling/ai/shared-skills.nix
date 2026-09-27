{ inputs }:

{
  archify = "${inputs.archify}/archify";
  autoresearch = "${inputs.autoresearch}/.agents/skills/autoresearch";
  datastar = ../../../.agents/skills/datastar;
  jj-ci = ../../../.agents/skills/jj-ci;
  rlm = ../../../.agents/skills/rlm;
  typesafe-ai = "${inputs.typesafe-skills}/skills/typesafe-ai";
  modern-web-guidance = "${inputs.modern-web-guidance}/skills/modern-web-guidance";
}
