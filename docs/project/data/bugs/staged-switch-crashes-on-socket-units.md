---
type: bug
stage: done
description: The staged switch's watch read NRestarts from every touched unit, so a candidate that restarted a socket crashed the watch and the dead-man reverted it.
generated:
  by: claude-code
  at: 2026-10-29T10:05:00Z
sources:
- id: switch
  resource: deploy/switch.nu
  title: The staged switch's watch, which judges each touched unit
- id: test
  resource: tests/staged-switch-units.nu
  title: The nushell-staged-switch check
- id: review
  resource: docs/ci-failure-review.md
  title: The failure record a revert fills in
---

# Bug: the staged switch crashes on socket units

## Symptom

homelab's canary staged main at `807fe228` on 2026-10-29 at 04:26 CDT and
rejected it with phase `deadman` and breached `watch`. The candidate had
activated: nixbot's service and socket restarted with the new GC-root rule. The
run then printed "Waiting for 1 units to settle..." and died with
`nu::shell::column_not_found`: "Cannot find column 'NRestarts'".

## Reproduction

Stage any candidate whose activation starts, restarts, or reloads a socket,
timer, or target, such as a change to a socket-activated service.
`systemctl show --property=...,Result,NRestarts nixbot.socket` prints no
`NRestarts`, because only services count restarts.

## Root cause

`assess` in `deploy/switch.nu` read `$row.NRestarts` and `$row.Result` from each
touched unit's state, and `unit-states` builds that state from what
`systemctl show` prints, which leaves out properties a unit type does not have.
Earlier candidates had touched only services. The dead-man worked as designed
and returned homelab to its previous system.

Because the running system's watch judges a candidate, every later revision of
main that still changes nixbot's configuration restarts nixbot.socket under the
old watch and is rejected the same way, until the fixed watch runs there.

## Fix

`unit-broke` (`deploy/switch.nu:151`) reads both properties as optional: no
restart count is no restart, and no result is no failure.
`tests/staged-switch-units.nu` judges a service, socket, timer, and target in
each state, and the `nushell-staged-switch` check runs it before every delivery.

Failure record (`docs/ci-failure-review.md`):

- **Failing job/check:** homelab's staged switch of `807fe228`, `deadman`.
- **Root cause and triggering condition:** the watch assumed every touched unit
  is a service; nixbot.socket was the first touched socket.
- **Invariant or assumption:** each touched unit reports `NRestarts` and
  `Result`.
- **Durable guarantee considered:** a unit-level check of the judgment for each
  unit type (added); a socket-activated service in `tests/deploy-revert.nix`
  would cover it end to end but runs only after landing, in `remoteChecks`.
- **Change made or reason no additional guarantee helps:** optional properties
  and the `nushell-staged-switch` check.
- **Architecture consequence:** a fix to the watch reaches a canary only through
  a candidate the old watch can judge, so it lands with nixbot's change
  reverted, or reaches homelab once by Clan.

## Key references

Verified anchor points (line numbers as of 2026-10-29):

- `deploy/switch.nu:151` — `unit-broke`
- `deploy/switch.nu:164` — `assess`
- `deploy/switch.nu:133` — `unit-states`
