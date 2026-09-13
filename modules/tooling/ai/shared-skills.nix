{ inputs }:

{
  archify = "${inputs.archify}/archify";
  jj-ci = ../../../.agents/skills/jj-ci;
  marimo-pair = "${inputs.marimo-pair}/skills/marimo-pair";
  retro-marimo-pair = "${inputs.marimo-pair}/skills/retro-marimo-pair";
  modern-web-guidance = "${inputs.modern-web-guidance}/skills/modern-web-guidance";
}
