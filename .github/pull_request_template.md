## Summary

<!-- One bullet per commit: its subject line, then its body indented two spaces. -->

-

## Impact

<!--
Pick one and keep the matching sentence:
**refactor**: No host's system or home closure changes, so delivering it creates no generation.
**behavior**: Changes user-facing behavior. After `luvus-deliver` moves main,
the agent that delivered switches asus with `system-switch --with-home`.
Create a NixOS generation only if the candidate system toplevel differs from
the active system.
**breaking**: Changes user-facing behavior and needs the manual steps below
when activating. Create a NixOS generation only if the candidate system
toplevel differs from the active system.
For breaking changes, add a "## Manual steps" section after this one.
Paste the verdict of `luvus-deliver risk`: the hosts it reaches and why it is
low, medium, or high risk. A high-risk delivery waits for the owner's approval
of its exact commit (AGENTS.md, "Delivery").
-->

## Validation

- luvus gate: `nix-fast-build --skip-cached --no-nom --flake path:.#checks.x86_64-linux`
  (`prek run --all-files` for documentation-only work)
- `prek run --all-files`
- nixbot: `nixbot/nix-eval` and `nixbot/nix-build` on the branch head
