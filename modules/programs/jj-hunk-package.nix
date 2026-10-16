{
  inputs,
  lib,
  pkgs,
}:

# nixpkgs has no jj-hunk, and its crates.io release trails the tags. Build the
# pinned tag from its own lock file; it has no git dependencies, so no hash.
pkgs.rustPlatform.buildRustPackage {
  pname = "jj-hunk";
  version = (lib.importTOML "${inputs.jj-hunk}/Cargo.toml").package.version;
  src = inputs.jj-hunk;
  cargoLock.lockFile = "${inputs.jj-hunk}/Cargo.lock";

  # The integration tests drive jj with jj-hunk as its diff editor, as
  # upstream's own flake does.
  nativeCheckInputs = [
    pkgs.jujutsu
    pkgs.git
  ];
  preCheck = ''
    export HOME=$(mktemp -d)
    mkdir -p $HOME/.config/jj
    cat > $HOME/.config/jj/config.toml << 'TOML'
    [merge-tools.jj-hunk]
    program = "jj-hunk"
    edit-args = ["select", "$left", "$right"]
    TOML
    export PATH="$PWD/target/${pkgs.stdenv.hostPlatform.rust.cargoShortTarget}/release:$PATH"
  '';

  meta = {
    description = "Non-interactive hunk selection for jj split, commit and squash";
    homepage = "https://github.com/laulauland/jj-hunk";
    license = lib.licenses.mit;
    mainProgram = "jj-hunk";
    platforms = [ "x86_64-linux" ];
  };
}
