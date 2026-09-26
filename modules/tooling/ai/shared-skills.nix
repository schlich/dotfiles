{ inputs }:

{
  archify = "${inputs.archify}/archify";
  jj-ci = ../../../.agents/skills/jj-ci;
  typesafe-ai = "${inputs.typesafe-skills}/skills/typesafe-ai";
  modern-web-guidance = "${inputs.modern-web-guidance}/skills/modern-web-guidance";
}
