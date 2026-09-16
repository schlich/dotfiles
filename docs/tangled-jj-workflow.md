# Tangled + Jujutsu workflow

This repository uses JJ as the change-management layer and keeps Git as the
interoperability transport. Existing GitHub remotes remain `origin`; a
repository enrolled in Tangled gets a separate `tangled` remote with
`tangled-init <remote-url>`.

## The lifecycle

1. Create logical change A and give it a meaningful description.
1. Run `jj-stack new`, implement B, then repeat for C.
1. Inspect with `jj-stack`, `jj-stack diff`, and `jj-stack each`.
1. Enroll once with `tangled-init <remote-url>`, then preview and push with
   `jj-stack push`.
1. In Tangled, choose “Submit as stacked PRs”.
1. For review feedback on A, run `jj-stack edit A`, make the correction, and
   inspect the rebased descendants before pushing again. Do the same for B or
   C; do not append “fix review” commits.
1. Run the canonical local checks, push the updated stack, and let Tangled
   advance the review round. Use Tangled’s interdiff view to review the
   evolution from the previous round.
1. Merge only after the stack and its CI are approved.

The important identity distinction is:

- **JJ change ID**: the durable logical identity of a change across rewrites.
- **Git commit ID**: one materialized version of that change; it changes when
  JJ edits or rebases it.
- **Tangled review round**: the externally visible evolution of that logical
  change after resubmission.

JJ 0.45.1 writes its change-ID header by default, and this configuration keeps
that invariant explicit because Tangled uses the header to associate rewritten
Git commits with the same reviewed change. Avoid raw `git rebase` on JJ-managed
stacks: it can discard or obscure the metadata that makes this identity useful.

## Agents and workspaces

One task owns one JJ workspace and one topic. Communicate change IDs and
explicit workspace paths, not ephemeral Git commit SHAs. Before editing an
earlier change, an agent checks its descendants and confirms that the workspace
belongs to its task. JJ then rebases the descendants automatically; ownership
guards in `codex-session.nu` and `jj-ci` prevent another task from casually
stealing or rewriting that workspace. Review the complete stack before
submission.

`jj-stack --json` is a small structured API for this tooling. It emits rows
with change ID, commit ID, description, author, parents, bookmarks, current
state, and conflict state, without parsing human-facing graph output.

## SSH, identity, and Spindles

The managed SSH config uses the existing local
`~/.ssh/id_ed25519_tangled` key for `tangled.org`; its private key is not in
this repository or the Nix store. The same key’s public half is configured as
JJ’s SSH signing identity. Upload that public key to Tangled and verify that
the author email `ty.schlich@gmail.com` is associated with the Tangled account;
the configuration does not change global identity attribution.

Tangled Spindles read YAML workflows from `.tangled/workflows`. This flake
already exposes canonical `nix fmt` and `nix flake check` entry points, so a
future repository workflow can invoke those commands directly instead of
duplicating forge-specific build logic. No CI migration is enabled here.
