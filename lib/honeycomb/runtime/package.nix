# The `honeycomb` command (honeycomb.nu), with the areas it files work under.
{
  lib,
  writeNuScriptBin,
  writeText,
}:

writeNuScriptBin "honeycomb" (
  ''
    $env.HONEYCOMB_AREAS = "${
      writeText "honeycomb-areas.json" (builtins.toJSON (import ../default.nix { inherit lib; }).areas)
    }"
  ''
  + builtins.readFile ./honeycomb.nu
)
