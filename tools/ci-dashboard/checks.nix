# The CI dashboard's checks: Hegel properties of feeds.mjs, and Bombadil's
# exploration of the page against the real server, whose `ci` and `gh` are
# fakes over a changing world (fake/). Each sees only the files it runs.
{ lib, pkgs }:

let
  bombadil = import ../../lib/bombadil.nix { inherit lib pkgs; };

  # package-lock.json's packages for this platform, unpacked from the
  # tarballs it pins. Install scripts do not run: koffi and libhegel ship
  # their binaries in these per-platform packages.
  lock = lib.importJSON ./package-lock.json;
  forHost =
    entry:
    builtins.elem "linux" (entry.os or [ "linux" ]) && builtins.elem "x64" (entry.cpu or [ "x64" ]);
  packages = lib.filterAttrs (path: entry: path != "" && forHost entry) lock.packages;
  nodeModules = pkgs.runCommand "ci-dashboard-node-modules" { } (
    lib.concatStrings (
      lib.mapAttrsToList (path: entry: ''
        mkdir -p "$out/${path}"
        tar -xzf ${
          pkgs.fetchurl {
            url = entry.resolved;
            hash = entry.integrity;
          }
        } -C "$out/${path}" --strip-components=1
      '') packages
    )
  );

  source =
    files:
    lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions files;
    };
in
{
  feeds =
    pkgs.runCommand "ci-dashboard-feeds"
      {
        src = source [
          ./package.json
          ./feeds.mjs
          ./feeds.test.mjs
        ];
        nativeBuildInputs = [ pkgs.nodejs ];
      }
      ''
        cp -r "$src" dashboard
        chmod -R u+w dashboard
        cd dashboard
        ln -s ${nodeModules}/node_modules node_modules
        node --test feeds.test.mjs
        touch "$out"
      '';

  exploration = bombadil.browserCheck {
    name = "ci-dashboard";
    specification = "ci-dashboard.ts";
    origin = "http://127.0.0.1:4173/";
    timeLimit = "3m";
    src = source [
      ./index.html
      ./server.mjs
      ./feeds.mjs
      ./fake
    ];
    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.curl
    ];
    setup = ''
      export CI_FAKE_STATE="$TMPDIR/world" CI_REPO="$TMPDIR/repo"
      # Bombadil's exploration is random too; the seed replays the world.
      export CI_FAKE_SEED="''${CI_FAKE_SEED:-$RANDOM$RANDOM}"
      echo "Fake CI world seed: $CI_FAKE_SEED"
      mkdir -p "$CI_FAKE_STATE" "$CI_REPO" "$TMPDIR/bin"
      for tool in ci gh; do
        printf '#!%s\nexec %s %s "$@"\n' ${pkgs.runtimeShell} ${lib.getExe pkgs.nodejs} "$PWD/fake/$tool.mjs" >"$TMPDIR/bin/$tool"
        chmod +x "$TMPDIR/bin/$tool"
      done
      PATH="$TMPDIR/bin:$PATH" node server.mjs >"$TMPDIR/server.log" 2>&1 &
      trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

      for _ in $(seq 60); do
        if curl --silent --fail http://127.0.0.1:4173/api/tower >/dev/null; then
          break
        fi
        sleep 0.5
      done
      if ! curl --silent --fail http://127.0.0.1:4173/api/tower >/dev/null; then
        cat "$TMPDIR/server.log"
        exit 1
      fi
    '';
  };
}
