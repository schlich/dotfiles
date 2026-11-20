---
type: plan
description: Reorganize every navigated collection to six members or fewer, with hexagonal navigation and selection-first keys shared by all tools.
created: 2026-11-19
generated:
  by: claude/claude-fable-5-2
  at: 2026-11-19T21:20:00Z
sources:
- id: model
  resource: lib/honeycomb/README.md
  title: the honeycomb model
- id: input
  resource: docs/input.md
  title: nested input contexts
- id: niri
  resource: docs/niri.md
  title: using niri
---

# Honeycomb: six to a cell, everywhere

## Context

The author asked for the flake to be reorganized around one limit: human working
memory holds about six things, so any collection of more than six needs a new
abstraction. The same request asks for Helix's selection-first grammar in basic
navigation and keybindings, and for navigation that follows a hexagonal tiling.
A census on 2026-11-19 found the limit broken almost everywhere: 169 niri binds,
52 flake inputs, 36 NixOS modules, 22 Den aspects, 34 top-level entries, 12
sections in `AGENTS.md`, and at runtime 50 local branches and 18 worktrees.
`lib/honeycomb/README.md` states the model.

## Approach

Treat every collection as a hexagonal cell with at most six members, and every
domain as a tree of such cells. Six direction keys (`H` `L` `Y` `U` `N` `M`)
select a member, `J` enters it and `K` leaves, in every tool; verbs act on the
selection. A flake check counts the collections and holds a baseline of the ones
already over six, which may only shrink, so each later task pays off entries
without a regression slipping in behind it.

Rejected: one large rewrite. It would move every module, rebind every key and
touch all four hosts in a single change that no gate could review, and it would
discard muscle memory before the new grammar is proven on one tool.

## Implementation Steps

### Task 1: Foundation

**Files:** Create: `lib/honeycomb/default.nix`, `lib/honeycomb/census.nix`,
`lib/honeycomb/baseline.nix`, `lib/honeycomb/tests.nix`,
`lib/honeycomb/README.md`. Modify: `flake.nix`

- [x] Hexagon arithmetic: neighbours, distance, ring, spiral, route, turn.
- [x] Cell trees: seat members, resolve an address, find crowded cells.
- [x] Census of directories, flake inputs, niri binds and rules, and `AGENTS.md`
  sections, audited against a baseline that only shrinks.
- [x] Flake checks `honeycomb-tests` and `honeycomb-census`.

### Task 2: One key grammar, exported

**Files:** Modify: `modules/programs/desktop/input-stack.nix`, `lib/honeycomb/`,
`niri/binds.nix`, `docs/input.md`

- [x] Add the six direction keys, the two depth keys, and the `NORMAL` and
  `SELECT` mode names to the exported `input-stack.json`, from `lib/honeycomb`.
- [x] Fail evaluation when a context declares a chord for a seat that ends on a
  key other than the seat's (`dotfiles.input.navigation`). A context that
  declares nothing is not checked, so Task 4 adds each tool's entry as it adopts
  the keys.

### Task 3: Niri binds as a tree

**Files:** Create: `niri/binds.nix`. Modify: `niri/config.kdl`,
`niri/keymap.nu`, `niri/keymap-emoji.nuon`, `niri/session.nu`,
`niri/workspace-overview.nu`, `modules/programs/desktop/desktop.nix`,
`docs/niri.md`

- [x] Group the binds into six named cells of at most six members each, and
  generate the `binds` block from that tree (`niri/binds.nix`).
- [x] Lay the areas out as one centre and six neighbours, each reached with
  Mod+Alt plus its direction key. Cycling sessions was dropped, not moved to
  spiral order: the launcher covers it.
- [x] Split motions from verbs: Mod selects, Shift acts on the selection. niri
  has no modes of its own, so there is no `SELECT`; Shift stands in for it.
- [x] Show niri's mode and at most six keys on the Noctalia bar, as the author
  decided on 2026-11-19 (`schlich/niri-hints`).

### Task 4: Terminal, multiplexer, editor and file manager

**Files:** Modify: `modules/tooling/terminals/ghostty.nix`,
`modules/programs/multiplexers/luvus.nix`, `modules/tooling/editors/helix.nix`,
`modules/programs/shell/yazi.nix`, `tests/bombadil/`

- [x] Give each tool the same direction and depth keys behind its leader. Each
  declares them in `dotfiles.input.navigation`, which the check from Task 2
  holds to the shared keys. Ghostty has no status line and shows nothing.
- [x] Keep Helix's native motions inside buffers; Y and U in its window menu
  move between buffers. Its pickers are unchanged.
- [x] The Bombadil keymap checks expect the full mode names and `Esc` to
  `NORMAL`. They do not assert six choices per level: Helix's and Yazi's own
  menus are longer, and trimming them is out of scope.

### Task 5: Den and modules

**Files:** Modify: `den/aspects/`, `den/model/profile.nix`,
`den/model/schema.nix`, `modules/nixos/`, `modules/home/`, `modules/programs/`,
`modules/tooling/ai/`

- [x] Group the aspects and the NixOS, home, program and AI modules into at most
  six named groups each (`modules/README.md` lists them); `den/` itself gains
  `model/` for its schema, policy and profile. The `scripts` and `tests`
  directories under `modules/tooling/ai` are still over six.
- [x] Split the profile: `hardware` holds the GPU and whether the machine is
  portable, and `profile` the six facts about its use.
- [x] Prove no host changed. Every system's and home's derivation was compared
  before and after with nix-diff, not built: the move changes only text that
  names a moved file (comments in embedded scripts, and the paths
  `nixpkgs-watch` records), and the profile split changes no derivation at all.

### Task 6: Flake inputs and the repository root

**Files:** Modify: `flake.nix`, top-level directories, `AGENTS.md`, `docs/`

- [ ] Group the 52 inputs: move the skill and agent-asset inputs behind one
  aggregating input or a locked source list outside `inputs`.
- [ ] Reduce the 34 top-level entries to six areas and move the rest under them.
- [ ] Regroup `AGENTS.md` and `docs/` into at most six sections each.

### Task 7: Runtime collections

**Files:** Create: `tools/honeycomb.nu`. Modify: `modules/programs/vcs/vcs.nix`,
`modules/programs/multiplexers/luvus.nix`

- [ ] `honeycomb census` counts branches, worktrees, luvus tasks, agent sessions
  and windows per area, and names the ones over six.
- [ ] Refuse a seventh open task or worktree until one is delivered or parked,
  and offer the delivered branches to prune.

## Spec changes

`spec/honeycomb` (new): the rule of six, the eight keys, the two modes, and the
census contract. `docs/input.md` and `docs/niri.md` change with Tasks 2 and 3.

## Verification

- `nix build path:.#checks.x86_64-linux.honeycomb-tests` and `honeycomb-census`
  pass.
- After each task, `lib/honeycomb/baseline.nix` is shorter and the census check
  still passes.
- Tasks 3 and 4: the Bombadil keymap checks pass, and the hint line of each tool
  shows the mode and no more than six choices.
- Task 5: `nix-suite diff` shows no closure change on any host.
- The work is finished when `baseline.nix` is empty.

## Out of scope

- Vendored trees whose layout another project owns, such as `docs/project/data`;
  they stay in the baseline until their upstream moves.
- Source files inside a tool's `src` directory beyond grouping by module.
- Learning or adapting keys from behaviour.

## Key references

Verified anchor points (line numbers as of 2026-11-19):

- `niri/config.kdl:407` — the `binds` block.
- `niri/keymap.nu:14` — `niri-keymap hints`, the always-on hint source.
- `modules/programs/desktop/input-stack.nix:67` — `dotfiles.input.contexts`.
- `modules/tooling/editors/helix.nix:68` — Helix `keys`.
- `modules/tooling/terminals/ghostty.nix:21` — Ghostty `keybind`.
- `modules/programs/shell/yazi.nix:92` — yazi `keymap.toml`.
- `den/model/profile.nix:76` — `behaviorAspects`.
- `den/model/schema.nix:68` — `servicesType`.
- `flake.nix:4` — `inputs`.
- `flake.nix:719` — `checks`, with the two honeycomb checks.
