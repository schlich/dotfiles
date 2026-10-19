## Summary

<!-- One bullet per JJ change: its subject line, then its body indented two spaces. -->

-

## Impact

<!--
Declare each revision's class with `ci impact set CLASS [STEP...]`; this
section only describes it for reviewers. Pick one and keep the matching sentence:
**refactor**: No NixOS generation changes; `ci land` verifies that every host closure is identical to the base. Landing it cuts no release.
**behavior**: Changes user-facing behavior. Landing it cuts a CalVer release
(`YYYY.MM.DD.N`), and the agent that lands it switches asus with
`system-switch --with-home`. Create a NixOS generation only if the candidate
system toplevel differs from the active system.
**breaking**: Changes user-facing behavior and needs the manual steps below
when activating. Landing it cuts a CalVer release. Create a NixOS generation
only if the candidate system toplevel differs from the active system.
For breaking changes, add a "## Manual steps" section after this one, matching
the steps given to `ci impact set breaking`.
-->

## Validation

- `ci preflight`
