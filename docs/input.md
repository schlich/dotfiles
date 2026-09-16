# Nested input contexts

Keyboard input is owned by a stable stack of semantic namespaces:

```text
desktop / Niri       · Super
  terminal / Ghostty · Alt (reserved semantic namespace; no global interception)
    multiplexer / Zellij · Ctrl+G
      editor / Helix  · Space (native modal namespace)
```

An event reaches the outer layer first. Niri consumes only its global
window-management actions, then Ghostty forwards ordinary terminal input,
Zellij consumes `Ctrl+G` only when its command namespace is entered, and Helix
retains its normal modal behavior. The static hierarchy is exported as
`$XDG_DATA_HOME/input-stack.json` for future help overlays or Noctalia UI.

## Ownership rule

- Niri owns machine-level and window-management actions.
- Ghostty owns terminal-emulator actions such as surfaces, tabs, splits, and
  terminal UI. It currently has no prefix bindings.
- Zellij owns terminal workspace, session, tab, and pane actions. Press
  `Ctrl+G`, then `f` to toggle floating panes; press `Ctrl+G` again to leave
  the nested namespace.
- Helix owns editor and modal actions. Space remains Helix's native command
  namespace, and its existing Tab customizations are unchanged.

Outer layers must not implement a shortcut merely because they can see it.
In particular, Niri does not claim plain Ctrl+C, Ctrl+Z, Ctrl+D, or ordinary
terminal editing keys.

## Adding a context

Add one context to `dotfiles.input.contexts` in the reusable input-stack
module, giving it a stable `name`, `implementation`, and semantic `scope`.
Set `leader` explicitly when the context needs a leader different from the
scope default. Existing leaders are intentionally stable: inserting a new
context does not renumber or otherwise change downstream leaders.

The scope defaults are `global = Super`, `application = Alt`, `nested =
Ctrl+G`, and `modal = Space`. Assertions reject duplicate effective leaders,
missing required contexts, a non-Niri outer context, and plain Ctrl as a
global leader. If a new context needs a leader not represented by those
defaults, assign it explicitly and document its owner here.

Runtime active-context tracking is intentionally not part of this static
configuration. A future `input-mode status` command can read process/focus
state and emit paths such as `desktop/niri/ghostty/zellij/helix`; the exported
JSON is the stable source for that extension.
