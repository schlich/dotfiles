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

## Six directions and two depths

The same eight keys move through every tree. On a staggered keyboard the six
direction keys ring `J` and `K`, the way a cell's neighbours ring it:

```text
   Y   U          nw  ne
 H  J K  L       w  in out  e
   N   M          sw  se
```

- `H` `L` `Y` `U` `N` `M` select the member in that direction.
- `J` goes into the selected member; `K` goes back out to its parent. Where
  a tool has a stack and no levels, they step down and up it.

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

| Axis | Keys     | Reads as       | In niri   |
| ---- | -------- | -------------- | --------- |
| x    | `H`, `L` | left and right | window    |
| y    | `Y`, `M` | up and down    | workspace |
| z    | `N`, `U` | in and out     | monitor   |

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
