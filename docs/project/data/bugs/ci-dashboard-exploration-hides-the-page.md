---
type: bug
stage: done
description: The CI dashboard's Bombadil exploration pressed Enter on a GitHub link, which opened a tab in front of the page and stalled the rest of the run.
generated:
  by: claude-code/opus-5.5
  at: 2026-10-17T01:05:00Z
sources:
- id: spec
  resource: tests/bombadil/ci-dashboard.ts
  title: the dashboard's Bombadil specification, its actions and properties
- id: page
  resource: tools/ci-dashboard/index.html
  title: the dashboard page, whose Actions run titles open GitHub in a new tab
---

# Bug: the CI dashboard's exploration hides the page behind a GitHub tab

## Symptom

Some runs of `ci-dashboard-bombadil` stopped exercising the page partway
through. From then on, Bombadil logged
`quiescence timer ... timed out waiting for response for Runtime.evaluate` after
every action and
`failed to apply action Click ... timed out waiting for response for Input.dispatchMouseEvent`
for every click, including after reloads. No property failed, so the check
passed with a run that tested nothing after the stall.

## Reproduction

Run the exploration outside the sandbox with its trace kept, as
`tools/ci-dashboard/checks.nix` sets it up. In three 3-minute runs, two stalled,
at 12 s and 125 s. Both stalls followed the same three actions: a click on an
Actions panel `Run detail · #N` summary, Tab, then Enter.

The trace's resource metrics rule out a long task. Before the stall, each state
took 0.1–0.5 s. Afterwards, each took 5.1 s, Bombadil's quiescence timeout, and
each click 10.1 s. Over the same states, the page's `task_duration` grew by only
0.07–0.27 s and its `script_duration` by about 0.01 s. The page was idle, not
busy.

A probe that recorded `document.visibilityState` and the focused element failed
in all three runs, at 10 s, 28 s, and 90 s. Each time, Tab had moved focus to an
Actions run title, such as `A target=_blank Flake check on feat-login`, and the
next Enter turned the page `hidden`. Space on the same link did not.

## Root cause

Actions run titles are `<a target="_blank">` links to GitHub
(`tools/ci-dashboard/index.html:2099`). The specification keeps its clicks off
them, and off the file input, with `a:not([target=_blank])`
(`tests/bombadil/ci-dashboard.ts:400`). Its keyboard actions had no such limit,
so Tab followed by Enter opened GitHub in a new tab in front of the dashboard. A
hidden page runs no `requestAnimationFrame` callbacks. Bombadil waits for one
before it captures a state, so every later quiescence check and input event
timed out. A reload reloads the hidden tab, so the stall survived reloads. The
page also stops following its log while hidden
(`tools/ci-dashboard/index.html:2376`). The page is correct; the specification
was wrong.

## Fix

The keyboard actions offer only Tab and Esc while focus is on an element that
the clicks avoid (`tests/bombadil/ci-dashboard.ts:419`, `:455`). A new property,
`dashboardStaysInFront` (`tests/bombadil/ci-dashboard.ts:168`), fails as soon as
the page is hidden. With the old keyboard actions, it failed in one of two runs,
at 1:45, and the probe failed in three of three. With the fix, five 3-minute
runs finished with no violation and no timeouts, and no state took longer than
1.4 s. Focus sat on a new-tab link in 31 states of the first three, and each
time only Tab or Esc followed. The `ci-dashboard-bombadil` check passed too.

## Key references

- 2026-10-16 — `tests/bombadil/ci-dashboard.ts:168` — `dashboardStaysInFront`
- 2026-10-16 — `tests/bombadil/ci-dashboard.ts:419` — `focusLeavesPage`
- 2026-10-16 — `tools/ci-dashboard/index.html:2099` — `actionsRow` title link
