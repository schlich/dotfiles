---
agent: ask
model: GPT-5.3-Codex
description: Refresh and use modalkit/keybindings API docs for reedline Helix mode
---

You are maintaining reedline Helix edit mode integrations with modalkit.

Goals:
1. Refresh docs from docs.rs rustdoc JSON for these exact versions:
- modalkit: 0.0.24
- keybindings: 0.0.2
2. Prune docs to symbols used by src/edit_mode/helix.rs:
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
3. Produce two outputs:
- Machine-readable JSON: .copilot/modalkit-rustdoc/modalkit-pruned.json
- Human-readable markdown: .copilot/modalkit-rustdoc/modalkit-api.md
4. Validate that imported symbols in src/edit_mode/helix.rs still match docs.

Execution plan:
- Run: nu .copilot/skills/modalkit-rustdoc/scripts/fetch-modalkit-docs.nu
- Run: nu .copilot/skills/modalkit-rustdoc/scripts/prune-modalkit-docs.nu
- Run: nu .copilot/skills/modalkit-rustdoc/scripts/build-modalkit-reference.nu
- Summarize diffs and any missing or renamed API symbols.

Rules:
- Do not change reedline source code unless explicitly asked.
- Keep extraction deterministic and version-pinned.
- Prefer concise signatures and first-line docs for quick lookup.
