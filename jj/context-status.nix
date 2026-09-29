# Shared by the shell, Starship, and the agent SessionStart hooks, so each
# refers to the same derivation.
{ pkgs }:
pkgs.writeNuScriptBin "context-status" (builtins.readFile ./context-status.nu)
