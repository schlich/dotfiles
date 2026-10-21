---
name: flake-add
description: Add a GitHub repository to the dotfiles flake as an input and wire its package, Home Manager module, overlay, or files into the configuration. Use when the user asks to add, install, or pull in a flake or a repository from GitHub, such as "add flake github.com/OWNER/REPO".
---

# Adding a flake from GitHub

The `flake-add` command does the mechanical part: it writes the input block
with a `follows` line for every input the two flakes share and a comment from
the flake's description, locks only that input, and reports where the outputs
could go. Choosing where they go, and whether the repository deserves trust,
stays with you and the user.

## 1. Check nixpkgs first

Look the package up with the Nix MCP server (`{action: info, query: NAME}`).
If nixpkgs ships it, add `pkgs.NAME` to `modules/home/packages.nix` and stop.
If nixpkgs ships an older version, run `npr NAME` and report what it finds
before adding an input. `flake-add` refuses a package nixpkgs already ships
unless it gets `--force`.

## 2. Dry-run it

Run `flake-add OWNER/REPO --dry-run --json | complete` from the Nushell
evaluate tool in the worktree that owns the task. It accepts `OWNER/REPO`,
`github:OWNER/REPO/REF`, or a GitHub URL. `--name` sets the input's name,
and `--rev` pins a branch, tag, or commit. `--comment` replaces the flake's
description with a reason the input exists.

The report's `follows` lists the shared inputs it will make the flake follow,
and `unfollowed` lists the rest. Pass `--keep nixpkgs` (comma-separated) when
the flake needs its own pin, such as a Rust toolchain newer than the
repository's: the `codex` and `rust-overlay` inputs are that case.

## 3. Review what you are trusting

`nix flake show` already ran the flake's outputs to build the report, and
delivery will build and activate them. Before writing, tell the user:

- who maintains the repository, and whether it is pinned to a tag or follows
  a branch (`--rev` pins one);
- any `nixConfig` it declares, such as an extra substituter, and whether it
  needs `allowUnfree`;
- anything `nix flake show` failed on, such as import-from-derivation.

## 4. Write and wire it

Run it again without `--dry-run`. The script checks that the edited
`flake.nix` evaluates before saving it, and leaves it untouched otherwise.
Then follow the report's `next`:

| Output | Where it goes |
| --- | --- |
| `packages.x86_64-linux.*` | `home.packages` in `modules/home/packages.nix` |
| `homeManagerModules.*` | `imports` in a module under `modules/programs/`, as `dicta.nix` does |
| `nixosModules.*` | a Den aspect for the hosts that need it |
| `overlays.*` | the overlay list in `den/aspects/home-manager-host.nix` |
| not a flake (skills, scripts) | `"${inputs.NAME}/PATH"`; skills go in `modules/tooling/ai/shared-skills.nix` |

When the input replaces or overrides something nixpkgs ships, declare
`dotfiles.nixpkgsWatch.NAME` in the same module.

`flake-add` writes `flake.nix` itself, so Claude Code's checkpoints do not
cover that edit; Git does, so commit before running it. A `flake.nix` whose
inputs block it cannot find goes through `fh add`, which also adds the name to
the `outputs` arguments.
Remove that name if `outputs` takes `inputs@{ ..., ... }`.

## 5. Finish the task

Run `nix fmt`, commit, and deliver through the repository's luvus workflow
as its `AGENTS.md` describes.
