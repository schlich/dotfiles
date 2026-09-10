# JJ Workbench

JJ-first desktop workbench for local Codex agent sessions. The first slice is
intentionally read-only apart from the confirmation-gated working-copy
description action.

## Architecture

- Tauri 2 shell with a React/TypeScript frontend.
- Rust `JjAdapter` invokes the selected repository's `jj` CLI and returns
  application-level snapshots.
- Rust `CodexTransport` supervises `codex app-server --stdio` and emits stable
  timeline events instead of exposing protocol messages to the UI.
- SQLite persists the schema needed for repositories, workspaces, sessions,
  execution events, and graph links under `$XDG_STATE_HOME/jj-workbench/state.sqlite3`
  (or `~/.local/state/jj-workbench/state.sqlite3`).

The provider boundary is deliberately small: Codex is the first provider, and
Pi/ACP can be added behind the same lifecycle without changing the JJ views.

## Development

From this directory:

```nu
npm install
npm run tauri:dev
```

The UI can also be previewed without Tauri:

```nu
npm run dev
```

The desktop process expects `jj` on `PATH`. Codex integration expects the
`codex` executable on `PATH`; set `JJ_WORKBENCH_CODEX_BIN` to use a pinned
binary during protocol development.

## Safety boundary

The backend validates that the selected directory is the JJ repository root,
serializes mutations per application instance, captures command failures, and
refreshes snapshots after mutations. No Git mutation command is generated.
Additional JJ mutations should follow the same `MutationResult` shape and add
an explicit confirmation in the frontend before invoking them.
