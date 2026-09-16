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

Run the short Hegel-themed demo:

```nu
bun run src/main.ts examples/hegel-demo.json
```

The demo is a guided tour of [the article's](https://drmaciver.com/2026/09/come-work-with-me-on-hegel/) central ideas: express a property
once, bind several language frontends to one core, generate a concurrent
workload, explore scheduler nondeterminism, then shrink and replay the
smallest failure. Start on `State the property`, press `↓` to walk the loop,
and use the inspector to narrate each step. It is intentionally a graph
fixture rather than a Hegel implementation; the point is to show how the
viewer can make a technical workflow explorable.

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
