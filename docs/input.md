# Nested input contexts

Keyboard input passes through a fixed stack of namespaces, each with one
leader:

```text
desktop     / Niri     · Super
terminal    / Ghostty  · Alt
multiplexer / Luvus    · Ctrl+Space (a prefix: one key follows)
editor      / Helix    · Space (Helix's own modal namespace)
```

A key reaches the outermost layer first. Niri consumes its window-management
binds, Ghostty its split and tab binds, Luvus the key after its prefix, and
everything else reaches the shell or Helix unchanged.
`modules/programs/input-stack.nix` declares the stack and exports it as
`$XDG_DATA_HOME/input-stack.json`, for hint bars and mode indicators to read.

## Ownership rule

- Niri owns machine-level and window-management actions on Super. Its one
  exception is the window switcher, Alt+Tab and Alt+\`.
- Ghostty owns splits and tabs on Alt (Alt+H/J/K/L, Alt+F, Alt+[ and ]).
  Splits and tabs replaced Zellij's panes and tabs on the same keys.
- Luvus owns agent panes, workspaces and its orchestration board behind
  Ctrl+Space. Its status row names the mode (`NORMAL` at rest) and lists the
  keys that follow the prefix; pressing the prefix twice sends it to the pane.
  It binds no direct shortcuts, so Alt stays with Ghostty.
  `modules/programs/luvus.nix` takes its prefix from this stack.
- Helix owns editor actions. Space is its native command namespace, and
  Alt+N/I/O stay with it.

An outer layer does not claim a key merely because it sees it first. Niri
leaves plain Ctrl+C, Ctrl+Z, Ctrl+D and other terminal editing keys alone.

## One set of navigation keys

Every context moves with the same eight keys
([lib/honeycomb/README.md](../lib/honeycomb/README.md)): `H` `L` `Y` `U` `N`
`M` for the six directions, `J` inward and `K` outward, each behind the
context's own leader. A context declares the chords it binds to them in
`dotfiles.input.navigation.NAME`, by seat. Evaluation fails when a chord
ends on a key other than its seat's, so a direction never means a different
key in a different tool. Niri's entry comes from `niri/binds.nix`; the other
contexts have none until they adopt the keys.

The exported JSON carries the keys, the mode names (`NORMAL`, `SELECT`) and
each context's navigation chords.

## Adding a context

Add one entry to `dotfiles.input.contexts` with a stable `name`, its
`implementation`, and its `scope`. The terminal and editor entries follow
`dotfiles.primary`. Scope leaders are stable: `global` is Super,
`application` is Alt, and `modal` is Space, so inserting a context never
moves another's leader. Set `leader` explicitly for a context whose scope
default is taken, and document its owner here.

Evaluation fails when a required context (desktop, terminal, editor) is
missing, when two contexts share a name or leader, when plain Ctrl is a
leader, or when the outermost context is not Niri on Super.

Tracking which context is active at runtime is not part of this static
configuration. A later `input-mode status` command can read focus state and
print a path such as `desktop/niri/ghostty/helix`, using the exported JSON as
its source.
