{
  inputs,
  lib,
  pkgs,
}:

# nixpkgs trails upstream by several releases, and the agent memory hooks,
# guarded MCP writes, and folder-scoped queries need a current IWE. Build the
# pinned tag from its own lock file; it has no git dependencies, so no hash.
pkgs.rustPlatform.buildRustPackage {
  pname = "iwe";
  version = (lib.importTOML "${inputs.iwe}/Cargo.toml").workspace.package.version;
  src = inputs.iwe;
  cargoLock.lockFile = "${inputs.iwe}/Cargo.lock";

  # iwe is the CLI, iwes the language server, and iwec the MCP server.
  cargoBuildFlags = [
    "--package=iwe"
    "--package=iwec"
    "--package=iwes"
  ];

  # The CLI tests expect the binary under target/ without the target triple
  # and exercise the full workspace; upstream CI runs them per release.
  doCheck = false;

  meta = pkgs.iwe.meta // {
    platforms = [ "x86_64-linux" ];
  };
}
