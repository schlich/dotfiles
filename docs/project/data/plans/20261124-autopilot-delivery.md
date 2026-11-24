---
type: plan
description: Let the luvus autopilot merge every gated task and deliver luvus/integration on its own, and give agents one command, luvus-ship, for the gate and the merge, with every step logged.
created: 2026-11-24
generated:
  by: claude-code/opus-5
  at: 2026-11-24T13:05:00Z
sources:
- id: autopilot
  resource: modules/tooling/ai/scripts/luvus-autopilot.nu
  title: luvus-autopilot
- id: ship
  resource: tools/luvus-ship.nu
  title: luvus-ship
- id: module
  resource: modules/programs/multiplexers/luvus.nix
  title: The luvus Home Manager module
stage: done
completed: 2026-11-24
---

# Deliver gated luvus tasks without a hand on each step

## Context

A finished task took six hand-run steps: prek, `luvus-jj sync`, the gate, the
merge into `luvus/integration`, `luvus-deliver`, and removing the worktree. On
2026-11-24 six tasks sat at `done` on homelab's board, and the autopilot ran
only on asus, where it merged opted-in chains and never delivered. The user
asked for the gates to need less from them, with logging and version control as
the safeguards.

## Approach

The autopilot merges every `done` task with a gate and a branch in the
repositories it lists (`done` means the gate passed). Tasks already done when it
first sees a repository stay a backlog it lists but never merges. On the one
host with `services.luvusDeliver` (homelab, the canary), it starts
`luvus-autodeliver.service` once `luvus/integration` has stayed put for ten
minutes with no task waiting to merge. That unit runs `luvus-deliver` unchanged,
so the risk verdict and its mitigations still decide. Beforehand it merges
`origin/main` in when the branch lacks it. Afterwards it removes the delivered
tasks' worktrees. A commit whose delivery failed is not retried until the branch
moves. Agents in sessions outside a luvus pane run `luvus-ship`, which gates and
merges exactly the commit the gate passed, under the lock the autopilot takes.

Every action goes to `events.jsonl` with the integration and main commits before
and after it, and each delivery's output goes to its own log with `watch-job`
reports. One pause covers the whole autopilot.

Rejected: `policy.autoDeploy` on asus. Its timer applies only the system, and
asus's home is standalone. Rejected: an autopilot switch of asus. Switching
another host stays the user's call (AGENTS.md).

## Implementation Steps

- [x] `gated-done` and `deliver-plan` in the autopilot, pure, with fixture tests
- [x] `deliver`, `log`, delivery state, the bar's delivery segment, and pruning
- [x] `luvus-ship`
- [x] Module options `autopilot.repositories` and `autopilot.deliver`, the
  delivery unit, and `services.luvusDeliver` on homelab
- [x] AGENTS.md's delivery section

## Spec changes

None: `data/spec/` has no delivery documents.

## Verification

`checks.luvus-autopilot` runs the plan and delivery fixtures and parses
luvus-ship; the gate builds both homes.

## Key references

Verified anchor points (as of 2026-11-24):

- [luvus-autopilot.nu](../../../../modules/tooling/ai/scripts/luvus-autopilot.nu)
  — `gated-done`, `deliver-plan`, `consider-delivery`, `main deliver`
- [luvus-ship.nu](../../../../tools/luvus-ship.nu) — `main`
- [luvus.nix](../../../../modules/programs/multiplexers/luvus.nix) —
  `luvus-autodeliver`
