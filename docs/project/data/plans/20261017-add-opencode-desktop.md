---
type: plan
description: Add OpenCode as an optional desktop AI client.
created: 2026-10-17
---

# Add OpenCode desktop client

## Context

Make the OpenCode desktop app available alongside the existing optional desktop
AI clients.

## Approach

Add upstream's `opencode-desktop` package to the shared desktop tooling profile
and expose `opencode` as a selectable primary desktop agent. Keep the existing
primary selection unchanged; the default alternate-client setting makes the app
available on the workstation.

## Implementation Steps

### Task 1: Add the desktop app

**Files:** Create: `modules/tooling/ai/opencode-desktop.nix`; Modify:
`den/aspects/users/terminal.nix`, `modules/tooling/interface.nix`

- [ ] Import the package module and add OpenCode to the desktop agent choices.

## Spec changes

None — this adds an existing desktop client without changing its behavior.

## Verification

Run `nix fmt` and validate the project graph with `iwe normalize` and
`iwe schema validate`.

## Out of scope

Changing the selected primary desktop agent or activating the configuration.

## Key references

Verified anchor points (line numbers as of 2026-10-17):

- `den/aspects/users/terminal.nix:30` — desktop client module imports
- `modules/tooling/interface.nix:76` — `desktopAgent` option
- `modules/tooling/ai/t3code.nix:16` — optional client selection pattern
