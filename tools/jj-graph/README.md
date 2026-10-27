# jj-graph

Plan, check, and normalize Jujutsu change graphs against the code's
dependency graph, after "Architectural Graph Engineering in Jujutsu": a
change graph should mirror what the code depends on, so every change
descends from the changes that define what it references (soundness) and
from nothing it does not need (minimality).

```nu
jj-graph check                       # how far trunk()..@ is from its normal form; exits 1 if not normal
jj-graph plan --cosmetic --hoist     # the normal form and the rebases that reach it; changes nothing
jj-graph normalize --cosmetic --hoist  # rewrite trunk()..@ into its normal form, as one operation
jj-graph normalize --mergiraf        # let mergiraf merge edits of one file that jj's text merge cannot
jj-graph symbols -r 'trunk()..@'     # what each change defines and references
jj-graph shapes -- cargo check       # boundary shapes; run a check in each affected change's tree
jj-graph shapes --every -- cargo test  # run it in every change (the guide's atomicity)
jj-graph skeleton design.dot features/*.feature  # a ghost graph from a Graphviz diagram and Gherkin specs
```

Every command takes `-r REVSET` (default `trunk()..@`) and `-R DIR`; most
take `--json`.

## What it does

| Guide                          | Command                 |                                                                                                                                                                                                                         |
| ------------------------------ | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| §3 Ghost graph                 | `skeleton`              | One empty change per diagram node, one per feature (holding its `.feature` file), and one per scenario; edges as parents, implied edges dropped, roots on `--onto`; a rerun reuses and updates what an earlier run made |
| §2 Atomicity                   | `shapes --every -- CMD` | Runs a project's own check in every change's tree                                                                                                                                                                       |
| §4 A, refactor precursor       | `normalize --cosmetic`  | Formatting and comment edits move into a change of their own, which defines nothing                                                                                                                                     |
| §4 B, orthogonal fork          | `normalize`             | A change leaves a parent it does not need                                                                                                                                                                               |
| §4 C, bugfix sifting           | `jj absorb`             | jj already moves hunks into the change that last touched those lines                                                                                                                                                    |
| §4 D, contract-first inversion | `normalize`             | A change moves below a later change it uses                                                                                                                                                                             |
| §5 Pass 1                      | `symbols`               | Definitions and references from each change's diff, with tree-sitter                                                                                                                                                    |
| §5 Pass 2                      | `normalize --hoist`     | A change that adds contracts and implementations gets a change of its new contracts below it                                                                                                                            |
| §5 Passes 3–4                  | `normalize`             | The normal form, computed directly, then reached with `jj rebase -s`                                                                                                                                                    |
| §5 Boundary shapes             | `shapes`                | Contract roots, sibling realizations, merges that use private internals, contracts that changed since the last version                                                                                                  |

## The model

`spec/Normalize.qnt` states the normal form and checks it; the Rust core in
`src/graph.rs` and `src/plan.rs` mirrors it function for function, and
`tests/conformance.rs` replays the specification's traces against it.

A change _requires_ another when it references a symbol the other defines;
and, for an original ancestor, when both define the same symbol, both touch
the same file and their diffs do not commute, or the change is an anchor. An
anchor is a working copy, or a change with children outside the scope: its
tree must not change. Each change also keeps the out-of-scope (trunk) commits
it was built on. The normal form is the transitive reduction of the closure
of these requirements: each change's parents are its required ancestors that
no other required ancestor descends from. It is unique, normalizing it again
changes nothing, every edge in it is a direct requirement, and `check`
reports nothing exactly on a graph that is already normal.

### Commuting edits of one file

Two changes that touch the same file commute when jj itself can move each
past the other. jj-graph asks it once per read of the graph
(`src/commute.rs`). The pairs it asks about are those whose order nothing but
a shared file keeps (`Graph::commutation_candidates`). For each pair it runs
`jj rebase -r u -A v` on an operation it never integrates, so the later change
`v`, and the changes between the two, go on without `u`, and `u` goes on top.
The diffs commute only if all of these hold:

- no change between them conflicts, and neither `u` nor `v` does;
- each keeps its own patch: the lines it removes and adds, in order;
- `u` on top has exactly the tree `v` had, so the pair ends where it started.

The specification takes the result as an input, `commutes`. Two changes
editing different functions of one file become siblings, and a change written
before the code it calls in the same file can move above it. Edits that jj's
text merge cannot separate, such as two changes on one line, keep their
order.

With `--mergiraf`, a conflict in `u` or `v` goes to
[mergiraf](https://mergiraf.org), a structural merge tool. jj runs it as an
external merge tool through `jj resolve`; jj-graph never links it, and runs
the program `JJ_GRAPH_MERGIRAF` names, or `mergiraf` on the path. A
resolution counts only if each change keeps its edit item by item, and `u` on
top holds what `v` held, though order and layout may differ. An item here is
a piece of a file: a named item, read with the same queries as definitions;
what a top-level unit holds outside its items; a comment; or the tokens
outside every unit. Each change must remove and add the same pieces it did
before the move. `normalize --mergiraf` then hands mergiraf every conflict the
plan's rebases leave, parents first, and gives each anchor its own tree back.
The check before integration holds each change mergiraf merged to the same
rule. A merge is judged against its parents as mergiraf merges them, on an
operation off the chain that is never integrated. `check` and `plan` take
`--mergiraf` too, so that they judge the graph by the same rule.

Three situations have no normal form jj-graph will apply:

- **A requirement cycle**: two changes need each other. `normalize` names
  each requirement in the cycle and why it holds.
- **A first merge**: the normal form would combine edits to one file that no
  change ever combined. Refused unless `--allow-new-combinations`; the result
  is still checked before it lands.
- **Anchor growth**: a change below an anchor uses a change outside the
  anchor's lineage, so soundness puts that change below the anchor and its
  files change. Refused unless `--allow-tree-changes`; an anchor allowed to
  grow may then change only the files of the changes and trunk commits it
  gains.

### Where this departs from the guide

The guide's crawler does not reach this normal form reliably, which the
specification shows with two of its tests:

- Pass 3 runs `jj rebase -r v -d "parents(u)"`. That pulls `v` out from under
  its own descendants, so a descendant that needed `v` loses it
  (`docSinkDropsADescendantsDependencyTest`). jj-graph rebases with `-s`,
  which keeps descendants on `v`.
- A crawler of local moves (add a missing parent, drop a covered one, sink a
  change below a parent it does not need) can stop short: in a stack
  `u → v → w` where `w` needs both and `v` needs neither, no single move is
  safe and makes progress (`crawlerStopsShortTest`). jj-graph computes the
  normal form directly and places changes in a topological order of it, which
  the specification proves never shows jj a cycle and always ends on the
  normal form.

The guide's minimality ("a direct parent iff the change references a symbol
defined there") is extended with the textual, anchor, and base requirements
above; without them a normalization could conflict, change the working copy,
or drop trunk commits a change was built on. The textual requirement holds
only where jj cannot commute the two diffs, so it costs no parallelism that a
clean rebase would allow. Pass 2 hoists only new
contracts: a precursor that changed or removed a contract would break the
code still written against the old one, so it would not build.

## Applying a plan

`normalize` never shows anyone half a plan (`spec/Apply.qnt`). It runs every
command on a detached chain of operations (`--at-op`,
`--no-integrate-operation`), then checks the chain's last operation: every
change has its planned parents, none gained a conflict, every anchor and
every workspace's working copy has the same tree, and every change's own diff
is unchanged (item by item, for a change mergiraf merged under `--mergiraf`).
Only then, and only if the repository's head operation is still
the one it started from, does it run `jj op integrate`. A failed command or
check leaves the repository as it was. If another operation races the
integration and leaves a change divergent, jj-graph reverts its own
operations with `jj op revert`, which keeps the other one.

## Splitting changes: precursors and contracts

Both splits run `jj squash --from v --insert-before v` with jj-graph as the
diff editor, so the new change below `v` gets one part of `v` and `v` keeps
its tree, its change ID, and its bookmarks. The part is planned from `v`'s
diff before jj runs, and assembled from whole top-level syntax units (an item
with its doc comments and attributes, an import, a statement), never lines.
The editor writes the planned files and gives every other file its parent's
version back, symlinks and permissions included. A planned file must parse
and hold exactly what it means to move, or its file moves nothing; the
symbols the graph uses come from the same plan, so the graph hoists exactly
what the split moves.

- `--cosmetic` (the guide's Pattern A): each unit whose tokens the change
  leaves alone, but whose layout, comments, or trailing commas it changes,
  takes its new text. The new change defines nothing and orders only by the
  files it touches, where its diff and theirs do not commute; a re-indent
  far from the change's other edits commutes with them, so the two end as
  siblings. Renames change tokens, so they stay with the change.
- `--hoist` (Pass 2): each top-level unit that holds only contracts (traits,
  interfaces, protocols, structs, enums, type aliases, module option
  declarations) that the file did not have, and that no implementation
  shares a name with (TypeScript overloads), goes in after the nearest unit
  before it that the old file has. Each name it uses that the file does not
  yet import gets an import of its own (`use a::D;`, `from m import D`,
  `import { D } from 'm';`, `import "io"`), so an import nothing in the part
  uses never comes along. In Nix a new option goes into the attribute set
  the old module already has for it. A change whose new contracts reference
  its own implementation is left alone.

Renamed, copied, and binary files never move anything, and neither do files
in languages jj-graph cannot read. A file the change adds moves its new
contracts too. A new Rust module brings the `mod` that declares it, when the
change adds that to a file it modifies, and stays behind when the declaring
file is new as well; a new Nix module never moves, since another module's
`imports` would have to come along.

## Skeletons: diagrams and features

`skeleton` reads one Graphviz digraph (`.dot` or `.gv`) and any number of
Gherkin feature files, and plans `spec/Skeleton.qnt`'s graph:

- Each diagram node becomes an empty change whose description is its label;
  `a -> b` makes `a`'s change a parent of `b`'s.
- Each feature becomes a root change (`spec(<file>): <feature>`) that adds
  its `.feature` file from the working copy, and each scenario an empty
  change (`feat(<file>): <scenario>`, with its steps) on its feature's
  change and on the components its `@needs:<node>` tags name (on a feature,
  rule, or scenario), or on the diagram's surface layer when it names none.

Edges another path implies are dropped. A rerun finds each change it made
by title and parents, brings descriptions and feature files up to date, and
creates only what is missing, all as one operation.

DOT is read as Graphviz reads it, with graphviz-rust's parser, and
`tests/dot_reading.rs` checks the reading against Graphviz's own `dot`. A
node's label is its last `label`, else the default in force where it was
first named (`node [label="feat: \N"]`), else its ID; `\N`, `\G`, and `\n`
mean what Graphviz shows for them, and an HTML label is read as its text.
`a -> {b c}` means an edge to each node of the subgraph, counting nodes an
earlier subgraph of the same name added. graphviz-rust reads less than DOT
(it needs the `subgraph` keyword, lowercase keywords, and cannot start an
edge with a subgraph), so jj-graph lexes the text first and hands
graphviz-rust the same graph within its grammar. An undirected `graph`, a
node that builds on itself, an unquoted keyword as a node ID, and node IDs
with `:` are refused.

## Reading definitions

Rust, Python, TypeScript, TSX, JavaScript, Go, and Nix are read with
tree-sitter (`src/queries/`, and a walk of the module's attribute sets for
Nix, where `options.*` declarations are contracts and other bindings are
values). A change defines every item it adds, removes, or changes, compared
by its syntax tree without comments, layout, or trailing commas, so a Python
statement dedented out of a block or a hole in a JavaScript array is a
change, and every member such an item declares (a trait's methods, a
struct's fields, an enum's variants). In JavaScript and TypeScript an item
includes its `export` and its `const` or `let`, and an export clause defines
the names it exports. A contract nested in an implementation (an impl
block's associated type) is part of the implementation. It references the
identifiers it inserts: in each top-level unit it changes, the uses a token
diff against the unit's old version finds inserted (each new use counts,
even of a name the unit already used), and every use in a unit it adds. A
unit it only moves or reformats references nothing, though a line diff would
see its lines as new. Methods of a trait implementation are named
after their type (`Db::get`), since callers reach them through the trait.
Names are matched by their simple name, so unrelated items that share a
name look related: that only adds requirements, which keeps a normalization
safe and makes it less parallel. Other files only count by path.

## Tests

- `tests/graph_properties.rs`: Hegel properties of the normal form, the plan,
  hoisting, anchor growth, and commuting pairs, with a brute-force search of
  every valid rewrite for small graphs.
- `tests/conformance.rs`: quint-connect replays `NormalizeWide` traces and
  compares all six state variables after every step.
- `tests/jj_end_to_end.rs`: random stories of commits in real repositories,
  normalized and then checked from outside (normal when read back, trees and
  own diffs unchanged, refusals change nothing, a second run does nothing),
  the guide's examples, and edits of one file that commute, that do not, and
  that commute only through mergiraf.
- `tests/extract_properties.rs`, `tests/split_properties.rs`: files in every
  language, moved, commented, reformatted, edited, and extended; what a
  change defines and uses, and what each split moves.
- `tests/dot_reading.rs`: random DOT texts read by jj-graph and by Graphviz's
  `dot -Tplain`, which must agree.
- `tests/module_properties.rs`, `tests/extract_examples.rs`,
  `tests/gherkin_examples.rs`: diffs against jj's own output, definitions,
  diagrams, features, skeletons, and merge leaks.
- `spec/*.qnt`: `quint test` runs the examples; the flake check simulates
  `NormalizeWide` and `SkeletonWide`, requires every `Witness*` to be
  violated (so no invariant passes vacuously), and model checks `Apply`
  (with liveness) and `Skeleton` with TLC. TLC over every graph of
  `NormalizeTiny` takes about twelve minutes and runs as a remote check.

```nu
# jj, quint, git, Graphviz's dot, and mergiraf on PATH; keep cargo's output
# outside the checkout, since `path:` flakes copy ignored files too.
$env.CARGO_TARGET_DIR = ($nu.temp-path | path join jj-graph-target)
cargo test
quint test --main=NormalizeExamples spec/Normalize.qnt
nix build path:.#checks.x86_64-linux.jj-graph-model
```

## Limits

- Name matching is by simple name; aliases, reflection, macros that build
  names, and string-keyed lookups are invisible, so a missed reference can
  order changes too loosely. `shapes -- CMD` runs a project's own check in
  each affected tree to catch what the names miss.
- Commutation is tested a pair at a time, in the graph as it was read, with
  the changes between the pair still in place. A normal form that drops
  several of a change's ancestors at once applies its patch where no test
  did, and a later read with fewer changes between a pair could judge it
  differently. The check before integration refuses any conflict or changed
  patch either makes.
- Each pair tested costs a rebase on a detached operation and a few reads, so
  `check` and `plan` take longer on stacks with many edits of one file.
- mergiraf's merges are judged item by item, which ignores order and layout:
  a change mergiraf merged may hold its items in another order or layout
  than its own diff had. Anchors keep their trees exactly, so a working copy
  over siblings mergiraf merged gets a diff that resolves their text
  conflict, which changes no item. mergiraf keeps each merge it makes for
  `mergiraf review` in its data directory; the merges made only to test a
  pair or to check a plan go to a directory that is removed afterwards.
- A hoisted part parses and holds what it should, but jj-graph cannot build
  it: an import's package name in Go is guessed from its path, and a new
  contract may rely on something only the implementation adds. Run
  `shapes --every -- CMD` after hoisting.
- Hoisting moves new top-level contracts only; a contract nested in an
  implementation, a new member of an old contract, and a contract in a
  renamed file stay with their change.
- The first-merge guard compares changes, not the trunk commits a change
  gains when it moves onto newer trunk; the check before integration still
  refuses any conflict that makes.
