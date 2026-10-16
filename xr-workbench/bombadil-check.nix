# Bombadil explores Fieldwork's workbench and MCP trace pages for two
# minutes each against tests/bombadil/fieldwork.ts. The IWSDK dev server and
# the bridge run as in development, over loopback HTTP, with the bridge on a
# fixture repository.
{ lib, pkgs }:

let
  bombadil = import ../lib/bombadil.nix { inherit lib pkgs; };

  # Named files only: a path: flake includes ignored ones, such as
  # node_modules and the dev server's certificate and private key in .iwsdk.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./server.py
      ./mcp_trace.py
      ./web/public
      ./web/src
      ./web/app.js
      ./web/cockpit.js
      ./web/index.html
      ./web/iwsdk.config.json
      ./web/mcp.css
      ./web/mcp.html
      ./web/mcp.js
      ./web/package.json
      ./web/pnpm-lock.yaml
      ./web/pnpm-workspace.yaml
      ./web/scene.js
      ./web/style.css
      ./web/vite.config.js
    ];
  };
  lockfiles = lib.fileset.toSource {
    root = ./web;
    fileset = lib.fileset.unions [
      ./web/package.json
      ./web/pnpm-lock.yaml
      ./web/pnpm-workspace.yaml
    ];
  };

  # The bridge's configuration catalog (FILES in server.py) and the
  # inventories it reads.
  fixtureFiles = [
    "den/aspects/xr.nix"
    "templates/devenv/devenv.nix"
    "templates/default/flake.nix"
    "den/inventory.nix"
    "flake.nix"
    "modules/nixos/base.nix"
    "docs/architecture.md"
    "AGENTS.md"
    ".agents/skills/example/SKILL.md"
    "modules/tooling/ai/example.nix"
  ];
  pnpmDeps = pkgs.fetchPnpmDeps {
    pname = "fieldwork";
    version = "0";
    src = lockfiles;
    fetcherVersion = 4;
    hash = "sha256-AFEnJhcxGXHIJp+qdvcWljoFUlW+7S/VGqgwKg7oiwU=";
  };

  # Random clicks seldom follow the one link between the pages, so each
  # page gets its own exploration.
  pages = {
    fieldwork = "/";
    fieldwork-mcp = "/mcp.html";
  };

  check =
    name: page:
    bombadil.browserCheck {
      inherit name src pnpmDeps;
      specification = "fieldwork.ts";
      origin = "http://127.0.0.1:8081${page}";
      pnpmRoot = "web";
      nativeBuildInputs = [
        pkgs.nodejs_24
        pkgs.pnpm
        pkgs.pnpmConfigHook
        pkgs.python3
        pkgs.d2
        pkgs.curl
      ];
      setup = ''
        repo="$TMPDIR/repo"
        for file in ${lib.escapeShellArgs fixtureFiles}; do
          mkdir -p "$repo/$(dirname "$file")"
          printf '# Fieldwork check fixture: %s\n' "$file" > "$repo/$file"
        done

        python3 server.py --repo "$repo" >"$TMPDIR/bridge.log" 2>&1 &
        (cd web; FIELDWORK_HTTP_PREVIEW=1 exec pnpm exec vite --strictPort) >"$TMPDIR/vite.log" 2>&1 &
        trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

        for _ in $(seq 120); do
          if curl --silent --fail http://127.0.0.1:8081/api/session >/dev/null; then
            break
          fi
          sleep 0.5
        done
        if ! curl --silent --fail http://127.0.0.1:8081/api/session >/dev/null; then
          cat "$TMPDIR/bridge.log" "$TMPDIR/vite.log"
          exit 1
        fi
      '';
    };
in
lib.mapAttrs' (name: page: lib.nameValuePair "${name}-bombadil" (check name page)) pages
