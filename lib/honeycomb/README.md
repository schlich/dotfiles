# Honeycomb

Working memory holds about six things. Honeycomb makes that a rule of this
repository: **no collection a person navigates holds more than six members.**
When a seventh arrives, the collection gains a level instead: its members are
grouped under a new, named abstraction, or one of them is retired.

## The cell

A hexagon has six neighbours, so a collection is a cell with its members
seated around it. Members can be cells themselves, which makes every domain a
tree that is six wide at most:

| Levels | Leaves it can hold |
| ------ | ------------------ |
| 1      | 6                  |
| 2      | 36                 |
| 3      | 216                |

Three levels are enough for anything here, including niri's 169 binds.

## Six directions, a stack and two depths

The same ten keys move through every tree. On a staggered keyboard the six
direction keys ring `J` and `K`, the way a cell's neighbours ring it, with
`I` and `O` just above:

```text
   Y   U  I  O        nw  ne  in  out
 H  J K  L           w  down up  e
   N   M              sw  se
```

- `H` `L` `Y` `U` `N` `M` select the member in that direction.
- `J` and `K` step down and up whatever is stacked.
- `I` goes into the selected member; `O` goes back out to its parent.

A path of directions is an address: `se`, then `e`, names one leaf for good,
so a place can be learned by hand, not by reading a list.

## Three axes

Three axes cross a cell, a third of a turn apart, and each is a pair of
opposite keys. A context puts one independent way of moving on each, so its
dimensions never share a key:

```text
        y+   z-            Y   U
     x-    ·    x+       H   ·   L
        z+   y-            N   M
```

| Axis | On the ring | Reads as       | Said plainly | In niri   | In a repository             |
| ---- | ----------- | -------------- | ------------ | --------- | --------------------------- |
| x    | `H`, `L`    | left and right | `H`, `L`     | window    | the topics beside this one  |
| y    | `Y`, `M`    | up and down    | `K`, `J`     | workspace | the changes of one topic    |
| z    | `N`, `U`    | in and out     | `I`, `O`     | monitor   | a change's files, or out to |
|      |             |                |              |           | the other working copies    |

Each axis has two spellings: its pair on the ring, and the plain pair for
left and right, up and down, in and out. The niri column is the example the
axes were drawn from; niri's binds do not follow it yet.

In a repository the three never mix. Topics sit side by side on trunk, so
moving between them is left and right. A topic's changes stack on one
another, child above parent as `jj log` draws them, so `jj next` is up and
`jj prev` is down. In goes from a change to what it touches; out goes from a
working copy to the others, one per task. Each of the three holds six at
most: six open topics, six changes to a topic, six working copies.

## While work is under way

The census in the flake counts what is written down. What accumulates while
work is under way is counted by the `honeycomb` command, in any Git
repository:

- `honeycomb census` counts the open topics (branches trunk does not hold
  yet), the task worktrees, the open luvus tasks and luvus's workspaces, and
  Claude's live sessions in each area, and says which pass six.
- `honeycomb prune` lists the branches trunk already holds, with their
  worktrees, and `--yes` removes them and closes the luvus workspaces open on
  them. It leaves a worktree with uncommitted work, or one luvus says is in
  use.
- `jj topics` lists the same open topics in a Jujutsu repository.

## Seven areas

Work is filed under seven areas, `areas` in `default.nix`: home at the
centre and six around it, the same flower as one cell and its neighbours.
Every tool that groups work groups it by these, so one map serves them all:

| Area | Cell | niri (Mod+Alt) | Knowledge base hub | Claude sidebar |
| --- | --- | --- | --- | --- |
| Home | centre | I | `index` | Home |
| Work | e | L | `work` | Work |
| Research | se | M | `research` | Research |
| Nix | sw | N | `nix` | Nix |
| AI & agents | w | H | `ai` | AI & agents |
| XR | nw | Y | `xr` | XR |
| Life | ne | U | `personal` | Life |

niri seats each area on its direction (`niri/binds.nix`) and opens it in
the area's first folder (`niri/session.nu`). Claude's sidebar mirrors the
flower on the in-out axis: pinned sessions, then the seven areas, then the
unfiled list, which is the outward side where new sessions arrive.

- `honeycomb sidebar` shows the sidebar refiled by area, and `--apply`
  writes it, keeping a copy of the old file, while the Claude desktop app is
  closed. The sections an area `absorbs` merge into it. An unfiled session
  joins the area whose folders hold its directory, else the area most of its
  project's filed sessions are in, so dragging one session into a section
  files its project from then on. Project folders stay out of this public
  repository; the sidebar is where they are filed.
- `honeycomb sessions` lists each area's live sessions and the ones to
  archive: those whose directory is gone, and those past the sixth most
  recently active in their area. `--archive` archives them, also with the
  app closed.

The tiling is that three-dimensional space seen along its diagonal. One step
along each of the three axes together returns to where it started, which is
why three dimensions fit on a flat ring of six keys. So the same move can be
made two ways: as a direction on the tiling, or as a signed step along
left-right, up-down or in-out. `project` turns a point of space into a cell
and `lift` turns a cell back into the nearest point.

`rotate` turns the view by a third: what moved along x now moves along z,
and so on round, and the same keys reach another dimension. A context with
more than three ways to move rotates between them, three at a time, and
never grows a fourth axis.

## Select first, then act

Borrowed from Helix. A motion moves the selection or, in `SELECT`, extends
it; a verb then applies to whatever is selected. So a key is either a motion
or a verb, never both, and every verb works on every selection. The base mode
is `NORMAL` in every tool, and `Esc` returns to it.

Because a level never offers more than six members and a handful of verbs, a
tool's own hint line can always show all of them.

## Moving over the tiling

`lib/honeycomb/default.nix` holds the arithmetic, in axial coordinates on
pointy-top hexagons:

- `neighbors`, `distance`, `opposite`, and `turn` for single steps.
- `ring` and `spiral` for cycling outward from a cell, clockwise from east:
  the order "next" and "previous" follow.
- `route` for the shortest walk between two cells, as directions.
- `flower` and `resolve` for seating members and following an address.
- `crowded` and `depth` for finding cells over six and sizing their split.

## The census

`lib/honeycomb/census.nix` counts every directory's entries, the flake's
inputs, niri's binds and window rules, and the sections of `AGENTS.md`. The
`honeycomb-census` flake check fails when:

- a collection passes six without an entry in `baseline.nix`; or
- a recorded collection shrinks or is paid off and its entry was not updated.

A recorded collection that grows only prints an evaluation warning, so work
elsewhere is not blocked while that collection waits for its regrouping.
Once a collection is regrouped and its entry removed, the limit is firm.

`baseline.nix` is therefore the list of debts. Pay one off by grouping its members under names a person would look for, not by
splitting files alphabetically.

Collections that only exist at runtime (branches, worktrees, agent sessions,
luvus tasks, windows in a workspace) are not in the flake, so this check
cannot see them; the plan in `docs/project/data/plans/` covers them.
