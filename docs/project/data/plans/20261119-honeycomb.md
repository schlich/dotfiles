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
  resource: docs/desktop/input.md
  title: nested input contexts
- id: niri
  resource: docs/desktop/niri.md
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
`niri/binds.nix`, `docs/desktop/input.md`

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
`docs/desktop/niri.md`

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

- [x] Group the 53 inputs into flakes of at most six under `lib/inputs`: five at
  the root (`system`, `builds`, `desktop`, `terminal`, `agents`) and ten groups
  inside them. One `flake.lock` still pins everything, and every input kept its
  revision. Modules read `inputs.NAME` as before; `nix-suite update`,
  `flake-add`, `nixpkgs-watch` and the delivery risk check resolve names through
  the groups.
- [ ] Reduce the 34 top-level entries to six areas and move the rest under them.
  Decided on 2026-11-19: planned here, and moved as its own task once no other
  session has a branch open, because every path in the documentation, CI, the
  delivery risk rules and every open branch changes. The layout:
  - `system/`: `den`, `hosts`, `modules`, `lib`, `deploy`, `secrets`.
  - `interface/`: `niri`, `noctalia`, `wallpapers`, `nushell`, `config.nu`,
    `jj`.
  - `agents/`: `agent`, `agent-monitor`, `copilot`, `mcp`, `plugins`, `jev`.
  - `tools/`: with `workbench`, `scripts`, `postmortem` and
    `templates` joining it, which then needs its own regrouping.
  - `tests/`: with `tests.nix` inside it.
  - `docs/`.
  - Exempt from the count, because a tool fixes where each sits: `flake.nix`,
    `flake.lock`, `AGENTS.md`, `nixbot.toml`, `prek.toml`, `.agents` and
    `.github`.
- [x] Regroup `AGENTS.md` and `docs/` into at most six sections each:
  `AGENTS.md` keeps its twelve sections as subsections of six headings, and
  `docs/` gains `agents`, `delivery` and `desktop` beside the architecture and
  the project graph.

### Task 7: Runtime collections

**Files:** Create: `lib/honeycomb/runtime/honeycomb.nu`. Modify:
`modules/programs/vcs/vcs.nix`, `modules/home/nix/nix.nix`, `AGENTS.md`,
`modules/tooling/ai/shared/global-agent-instructions.md`

- [x] `honeycomb census` counts open topics, task worktrees and open luvus
  tasks, and names the ones over six; `jj topics` lists open topics in a Jujutsu
  repository. Agent sessions and windows per area are not counted yet.
- [x] The version-control policies for Git and Jujutsu hold each to six, name
  the three axes of a repository, and delete a branch once `main` holds it;
  `honeycomb prune` lists and removes delivered branches with their worktrees.
- [ ] Refuse a seventh open task or worktree mechanically. Today the limit is a
  written policy that agents follow; nothing stops `luvus worktree create`. On
  2026-11-19 this repository had 7 open topics, 18 worktrees and 12 open tasks,
  with 57 delivered branches waiting to be pruned.

### Task 8: One map of areas

**Files:** Create: `lib/honeycomb/runtime/tests.nu`. Modify:
`lib/honeycomb/default.nix`, `lib/honeycomb/runtime/honeycomb.nu`,
`niri/binds.nix`, `niri/session.nu`, `modules/home/files.nix`,
`modules/home/nix/nix.nix`, `flake.nix`

- [x] The seven areas live once, in `lib/honeycomb/default.nix`, with each one's
  cell, knowledge-base hub, folders and the sidebar sections it absorbs; niri's
  binds, its session presets and the `honeycomb` command read them.
- [x] `honeycomb sidebar` refiles Claude's sidebar as pinned, the seven areas
  and the unfiled list, and `honeycomb sessions` names the sessions to archive
  so each area holds six live ones. On 2026-11-19 the sidebar had ten sections
  and 41 live sessions: 19 under Nix and 18 unfiled, 27 to archive.
- [x] `honeycomb census` counts luvus's workspaces and Claude's sessions per
  area; `honeycomb prune --yes` closes the luvus workspaces of what it removes.
- [ ] File the knowledge base's nine hubs under the seven areas: `shell`,
  `career` and `inbox` have no area.
- [x] Count niri windows per area workspace (`honeycomb flower`).

### Task 9: The flower on the phone

**Files:** Create: `lib/honeycomb/runtime/package.nix`,
`lib/honeycomb/runtime/hub/` (server, page, service worker, icon, NixOS module).
Modify: `lib/honeycomb/runtime/honeycomb.nu`,
`modules/tooling/ai/claude/claude-desktop.nix`,
`modules/nixos/homelab/homelab.nix`, `flake.nix`

- [x] `honeycomb flower` snapshots what each area holds: live Claude sessions,
  open luvus tasks with their changed files, windows on the area's niri
  workspace and the hub's notes.
- [x] An http-nu hub on homelab, published with Tailscale Serve, keeps the last
  snapshot and a queue of actions; asus syncs with it every minute.
- [x] A home-screen page draws one cell and six around it per screen and moves
  along the three axes with the phone's gestures: tap, flick, spread and back
  for in and out, sideways swipes for siblings, vertical swipes for the next
  six.
- [x] Selecting an item is SELECT mode with its actions around it: open a
  session in Claude, file it into another area, archive it, or list a task's
  changed files. Filing and archiving wait for asus while Claude runs.
- [ ] Try the gestures on the Pixel and tune the flick and swipe thresholds. On
  2026-11-19 only headless Chromium had rendered the page; no gesture had been
  tried on a touch screen.

## Spec changes

`spec/honeycomb` (new): the rule of six, the eight keys, the two modes, and the
census contract. `docs/desktop/input.md` and `docs/desktop/niri.md` change with
Tasks 2 and 3.

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
