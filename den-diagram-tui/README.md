# den-diagram-tui

An OpenTUI viewer for [den-diagram](https://denful.dev/ecosystem/den-diagram/)
Graph IR. It renders the graph as a scrollable terminal diagram and provides
an inspector for the selected node.

## Run

From this directory, install the native OpenTUI dependency once and start the
fixture:

```nu
bun install
bun run start
```

Open a den-diagram JSON export or Mermaid source instead:

```nu
bun run src/main.ts ./path/to/diagram.json
bun run src/main.ts ./path/to/diagram.mmd
```

For this repository's evaluated Den fleet, export the Graph IR with the
library's fleet adapter and open it in the TUI:

```nu
nix eval --raw --expr '
let
  repo = builtins.getFlake (toString ./.);
  diagram = builtins.getFlake "github:denful/den-diagram";
in
  diagram.lib.toJSON (diagram.lib.fleet.of {
    hosts = repo.den.hosts;
    flakeName = "dotfiles";
  })
' | save /tmp/dotfiles-den-diagram.json
bun run src/main.ts /tmp/dotfiles-den-diagram.json
```

The JSON reader accepts den-diagram's `toJSON` shape (`scopes`, `nodes`, and
`edges`) and also accepts a graph nested under `graph`. Mermaid support is a
small convenience for opening the source emitted by `toMermaid`; the viewer
does not need Mermaid or Graphviz installed.

Keys: `↑`/`↓` select a node, `PgUp`/`PgDn` scroll, `Home`/`End` jump through
nodes, `r` reload the file, and `q` or `Esc` quits.
