## Summary

<!-- One bullet per JJ change: its subject line, then its body indented two spaces. -->

-

## Impact

<!--
Pick one and keep the matching sentence:
**refactor**: No NixOS generation changes; CI verifies that every host closure is identical to the base. Landing it cuts no release.
**behavior**: Changes user-facing behavior. Landing it cuts a CalVer release (`YYYY.MM.DD.N`); activate it deliberately.
**breaking**: Changes user-facing behavior and needs the manual steps below when activating. Landing it cuts a CalVer release.
For breaking changes, add a "## Manual steps" section after this one.
-->

## Validation

- `ci validate`

<!-- Keep the trailer last: the squash commit carries it to main, where `ci release` reads it. -->

Impact: \<refactor|behavior|breaking>
