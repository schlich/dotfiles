{
  inputs,
  pkgs,
}:

# nixpkgs still ships 18.23. 18.24 captures agent sessions as threads, with
# `atuin resume` to continue one in another agent and MCP tools to search
# them. Upstream's flake builds the pinned tag with crane.
inputs.atuin.packages.${pkgs.stdenv.hostPlatform.system}.atuin
