---
type: bug
stage: done
description: After the move from jj topics to luvus branches, nixbot built luvus/* branches but still registered garbage-collection roots only for jj-* ones.
generated:
  by: claude-code
  at: 2026-10-29T09:10:00Z
sources:
- id: module
  resource: modules/nixos/nixbot.nix
  title: nixbot's service settings on homelab, its branch rules among them
- id: toml
  resource: nixbot.toml
  title: the branches nixbot builds, read from main
- id: nixbot-config
  resource: https://github.com/Mic92/nixbot/blob/b1f699803858e42071cffe41f5c3499f02729f07/nixbot/nixbot/config.py
  title: nixbot's BranchConfigDict, which decides what builds and what is rooted
---

# Bug: nixbot roots only jj topics

## Symptom

`docs/nixbot.md` said nixbot roots each topic's outputs until it lands, but
nothing nixbot built for `luvus/integration` or a task branch was rooted on
homelab. A garbage collection between nixbot's build of `luvus/integration` and
delivery could drop those outputs, so main's build of the same commit, or the
next luvus gate's `--skip-cached` lookup in Harmonia, would rebuild them.

## Reproduction

Push any `luvus/*` branch and let nixbot build it. Its outputs have no root
under `/nix/var/nix/gcroots/per-user/nixbot` unless main has built the same
attribute to the same output.

## Root cause

nixbot takes two lists of branch globs. `build_branches` in the repository's
`nixbot.toml` replaces the service's globs for deciding what to build, while
`registerGCRoots` is read only from the service's own `branches` rules
(`BranchConfigDict.do_register_gcroot` in nixbot's `config.py`). The move to
luvus changed `nixbot.toml` from `jj-*` to `luvus/*` (`7db5f2c0`) but left
`branches.topics.matchGlob = "jj-*"` in `modules/nixos/nixbot.nix`, a rule no
pushed branch matches any more.

## Fix

`branches.topics.matchGlob` is `luvus/*` (`modules/nixos/nixbot.nix:118`), the
glob `nixbot.toml` builds (`nixbot.toml:7`), and both files say that the two
must agree. Roots are per attribute, so a branch's newer result stands in for
main's until main builds again, as it did for jj topics. The fix reaches homelab
when it is delivered and the canary deploys it.

## Key references

Verified anchor points (line numbers as of 2026-10-29):

- `modules/nixos/nixbot.nix:117` — `branches.topics`
- `nixbot.toml:7` — `build_branches`
- `docs/nixbot.md:17` — what nixbot builds and roots
