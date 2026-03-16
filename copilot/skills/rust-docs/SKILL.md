---
name: modalkit-rustdoc
description: Fetch, prune, and cache modalkit/keybindings rustdoc JSON for reedline Helix mode. Includes Nushell scripts to build a compact JSON + markdown API reference.
---

# modalkit Rustdoc Cache Skill

Use this skill when working on reedline Helix integration and you need fast, local API reference for modalkit/keybindings.

## Scope

- Targets reedline usage in src/edit_mode/helix.rs
- Pins versions:
  - modalkit = 0.0.24
  - keybindings = 0.0.2
- Extracts symbols:
  - TerminalKey
  - BindingMachine
  - EdgeEvent
  - EdgeRepeat
  - EmptyKeyState
  - InputBindings
  - InputKey
  - ModalMachine
  - Mode
  - ModeKeys

## Files

- scripts/fetch-modalkit-docs.nu
- scripts/prune-modalkit-docs.nu
- scripts/build-modalkit-reference.nu
- references/helix-symbols.txt

## Typical workflow

1. Fetch compressed rustdoc JSON and decompress:

```nu
nu scripts/fetch-modalkit-docs.nu
```

2. Prune relevant symbols into one compact JSON:

```nu
nu scripts/prune-modalkit-docs.nu
```

3. Render markdown reference for quick reading:

```nu
nu scripts/build-modalkit-reference.nu
```

## Output locations

- .copilot/modalkit-rustdoc/raw/modalkit-0.0.24.json
- .copilot/modalkit-rustdoc/raw/keybindings-0.0.2.json
- .copilot/modalkit-rustdoc/modalkit-pruned.json
- .copilot/modalkit-rustdoc/modalkit-api.md

## Notes

- docs.rs rustdoc JSON payloads are zstd compressed.
- keybindings APIs are needed because modalkit re-exports and depends on keybindings traits/types used by reedline.
