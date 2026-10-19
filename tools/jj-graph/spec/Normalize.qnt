// The normal form of a Jujutsu change graph, as jj-graph computes it.
//
// "Architectural Graph Engineering in Jujutsu" asks for a change graph that
// mirrors the code's dependency graph: every change descends from the changes
// that define what it references (soundness), and from nothing it does not
// need (minimality). It reaches that graph with a four-pass crawler: extract
// each change's definitions and references, hoist contracts out of mixed
// changes, sink changes below parents they do not use, and reduce redundant
// parents. This module states the target the crawler should reach as a pure
// function, the way jj-graph computes it, and checks the properties the
// document promises of it.
//
// Three things the document's rules leave out decide whether a rewrite is
// safe, so the requirements here are wider than "references a definition":
//
// - Text. Two changes that touch the same file may not commute: moving one
//   off the other can conflict. A change keeps every original ancestor it
//   shares a file with, and every one that defines a symbol it also defines.
// - Anchors. A working-copy change, or one with a child outside the rewrite,
//   must keep its tree: files on disk, or a descendant nobody asked to move,
//   would change. An anchor keeps every original ancestor, so it becomes a
//   merge of the lines it used to sit on.
// - The base. A change keeps every out-of-scope (trunk) commit it was built
//   on. Nothing here knows what trunk defines, so nothing drops it.
//
// With those, the requirements form a relation R on the changes in scope. If
// R has a cycle, no graph satisfies it (a change would be its own ancestor).
// Otherwise the normal form is the transitive reduction of the closure of R
// together with the base requirements: each change's parents are exactly its
// required ancestors that no other required ancestor already descends from.
// That graph is unique, so normalizing twice changes nothing, and it has no
// edge that is not itself a requirement.
//
// The crawler's local moves do not reach it reliably. Its Pass 3 runs
// `jj rebase -r v -d "parents(u)"`, which pulls v out from under its own
// descendants: a descendant that needs u through v loses u (see
// docSinkDropsADescendantsDependencyTest). A crawler that only adds, drops,
// and sinks edges can also stop short: in a chain u -> v -> w where w needs
// both u and v but v does not need u, no single move is both safe and
// progressive (see crawlerStopsShortTest). jj-graph therefore computes the
// normal form directly and executes it as a plan.
//
// The plan sets each change's parents with `jj rebase -s v -o P...`, which
// moves v with its descendants, in a topological order of the normal form.
// The state machine below runs every such order and checks that jj never sees
// a cycle, that a change it has placed never moves again, and that the plan
// ends on the normal form. Contract hoisting (Pass 2) inserts a twin before a
// mixed change and gives it the change's contract definitions; it runs first,
// and only where the contract part does not reference the change's own
// implementation.
module Normalize {
  // ---------------------------------------------------------------------
  // Parameters
  // ---------------------------------------------------------------------

  // The changes in scope, in a topological order of the original graph: a
  // change's original parents come earlier in the list or from BASES.
  const ORDER: List[str]
  // Out-of-scope commits the scope sits on, such as trunk, and their
  // ancestry: (x, y) when x is a proper ancestor of y. Transitively closed.
  const BASES: Set[str]
  const BASE_ANC: Set[(str, str)]
  // The name of each change's contract twin, for hoisting.
  const TWIN: str -> str
  // The vocabulary of the generated graphs: every symbol, the ones that are
  // contracts (traits, interfaces, protocols, schemas), and every file.
  const SYMS: Set[str]
  const CONTRACTS: Set[str]
  const FILES: Set[str]

  pure val COMMITS: Set[str] = ORDER.foldl(Set(), (s, c) => s.union(Set(c)))
  pure val POS: str -> int =
    COMMITS.mapBy(c => ORDER.indices().fold(0, (acc, i) => if (ORDER[i] == c) i else acc))

  // ---------------------------------------------------------------------
  // Changes and graphs
  // ---------------------------------------------------------------------

  // What a change's diff defines, references, and touches. `anchor` marks a
  // change whose tree must not change. `crefs` and `cfiles` are the
  // references and files of its contract part, for hoisting.
  type Change = {
    defs: Set[str],
    refs: Set[str],
    files: Set[str],
    anchor: bool,
    crefs: Set[str],
    cfiles: Set[str]
  }

  // A graph is the set of changes in scope, each change's parents (changes in
  // scope or BASES), and each change's facts.
  type Graph = {
    scope: Set[str],
    parents: str -> Set[str],
    info: str -> Change
  }

  pure def nodesOf(g: Graph): Set[str] = g.scope.union(BASES)

  pure def edgesOf(g: Graph): Set[(str, str)] =
    g.scope.map(c => g.parents.get(c).map(p => (p, c))).flatten().union(BASE_ANC)

  // Transitive closure of a relation over the given nodes (Warshall).
  pure def closure(r: Set[(str, str)], nodes: Set[str]): Set[(str, str)] =
    nodes.fold(r, (acc, k) => {
      val into = acc.filter(e => e._2 == k).map(e => e._1)
      val outOf = acc.filter(e => e._1 == k).map(e => e._2)
      acc.union(into.map(i => outOf.map(j => (i, j))).flatten())
    })

  // (x, y) when x is a proper ancestor of y.
  pure def ancestry(g: Graph): Set[(str, str)] = closure(edgesOf(g), nodesOf(g))

  pure def ancestorsIn(a: Set[(str, str)], v: str): Set[str] =
    a.filter(e => e._2 == v).map(e => e._1)

  pure def isAcyclic(g: Graph): bool = ancestry(g).forall(e => e._1 != e._2)

  pure def withParents(g: Graph, parents: str -> Set[str]): Graph =
    { ...g, parents: parents }

  // ---------------------------------------------------------------------
  // Requirements
  // ---------------------------------------------------------------------

  // v requires u (u must stay a proper ancestor of v) when v references a
  // symbol u defines; and, for an original ancestor u, when both define the
  // same symbol, when both touch the same file, or when v is an anchor.
  pure def requires(g: Graph, a: Set[(str, str)], u: str, v: str): bool = {
    val iu = g.info.get(u)
    val iv = g.info.get(v)
    val before = a.contains((u, v))
    and {
      u != v,
      or {
        iv.refs.intersect(iu.defs) != Set(),
        before and iu.defs.intersect(iv.defs) != Set(),
        before and iu.files.intersect(iv.files) != Set(),
        before and iv.anchor,
      },
    }
  }

  pure def requirementsWith(g: Graph, a: Set[(str, str)]): Set[(str, str)] =
    tuples(g.scope, g.scope).filter(e => requires(g, a, e._1, e._2))

  pure def requirements(g: Graph): Set[(str, str)] = requirementsWith(g, ancestry(g))

  // The out-of-scope commits v was built on.
  pure def baseNeeds(g: Graph, a: Set[(str, str)], v: str): Set[str] =
    ancestorsIn(a, v).intersect(BASES)

  // Every proper-ancestor pair the normal form must have: the closure of the
  // requirements, the base each change was built on, and the base's own
  // ancestry.
  pure def requiredAncestry(g: Graph): Set[(str, str)] = {
    val a = ancestry(g)
    val base = g.scope.map(v => baseNeeds(g, a, v).map(x => (x, v))).flatten()
    closure(requirementsWith(g, a).union(base).union(BASE_ANC), nodesOf(g))
  }

  // The changes that take part in a requirement cycle.
  pure def cycleMembers(g: Graph): Set[str] = {
    val rs = closure(requirements(g), g.scope)
    g.scope.filter(v => rs.contains((v, v)))
  }

  pure def normalizable(g: Graph): bool = cycleMembers(g) == Set()

  // ---------------------------------------------------------------------
  // The normal form
  // ---------------------------------------------------------------------

  // Each change's parents: its required ancestors that no other required
  // ancestor descends from (the transitive reduction). Meaningful only when
  // the graph is normalizable.
  pure def normalParents(g: Graph): str -> Set[str] = {
    val n = requiredAncestry(g)
    g.scope.mapBy(v => {
      val below = ancestorsIn(n, v)
      below.filter(x => not(below.exists(y => n.contains((x, y)))))
    })
  }

  pure def normalForm(g: Graph): Graph = withParents(g, normalParents(g))

  pure def isNormal(g: Graph): bool = normalizable(g) and normalParents(g) == g.parents

  // The changes in scope an anchor would gain in the normal form. Keeping
  // every original ancestor is not enough to keep an anchor's tree: when an
  // ancestor references a change outside the anchor's lineage, soundness
  // puts that change below the ancestor, and so below the anchor, whose
  // files change. No valid graph avoids it, so jj-graph refuses unless told
  // to let those trees change.
  pure def anchorGrowth(g: Graph): Set[(str, str)] = {
    val before = ancestry(g)
    val after = requiredAncestry(g)
    g.scope.filter(h => g.info.get(h).anchor).map(h =>
      ancestorsIn(after, h).intersect(g.scope).exclude(ancestorsIn(before, h)).map(x => (x, h))
    ).flatten()
  }

  // ---------------------------------------------------------------------
  // Checks (what `jj-graph check` reports)
  // ---------------------------------------------------------------------

  // A requirement the graph does not satisfy: v references what u defines,
  // but u is not an ancestor of v (unsound lineage).
  pure def unsatisfied(g: Graph): Set[(str, str)] = {
    val a = ancestry(g)
    requirementsWith(g, a).filter(e => not(a.contains(e)))
  }

  // A parent that another parent already descends from.
  pure def redundant(g: Graph): Set[(str, str)] = {
    val a = ancestry(g)
    g.scope.map(v => {
      val ps = g.parents.get(v)
      ps.filter(p => ps.exists(q => a.contains((p, q)))).map(p => (p, v))
    }).flatten()
  }

  // A parent that no requirement asks for (the edge only orders history).
  pure def unneeded(g: Graph): Set[(str, str)] = {
    val n = requiredAncestry(g)
    g.scope.map(v => g.parents.get(v).filter(p => not(n.contains((p, v)))).map(p => (p, v))).flatten()
  }

  pure def violationFree(g: Graph): bool = and {
    normalizable(g),
    unsatisfied(g) == Set(),
    redundant(g) == Set(),
    unneeded(g) == Set(),
  }

  // ---------------------------------------------------------------------
  // Soundness and minimality, as the document states them
  // ---------------------------------------------------------------------

  // Soundness (well-typed lineage): every symbol v references that some change
  // in scope defines is defined by v or one of its ancestors. Symbols defined
  // only outside the scope come from the base.
  pure def sound(g: Graph): bool = {
    val a = ancestry(g)
    val defined = g.scope.map(u => g.info.get(u).defs).flatten()
    g.scope.forall(v => {
      val lineage = ancestorsIn(a, v).intersect(g.scope).union(Set(v))
      g.info.get(v).refs.intersect(defined).subseteq(lineage.map(u => g.info.get(u).defs).flatten())
    })
  }

  // Minimality (transitive reduction), generalized to all requirements: every
  // edge is a direct requirement, and no parent is an ancestor of another.
  pure def minimal(g: Graph): bool = {
    val a = ancestry(g)
    val r = requirementsWith(g, a)
    g.scope.forall(v => {
      val ps = g.parents.get(v)
      ps.forall(p => and {
        or {
          r.contains((p, v)),
          BASES.contains(p) and baseNeeds(g, a, v).contains(p),
        },
        not(ps.exists(q => q != p and a.contains((p, q)))),
      })
    })
  }

  // Removing any one edge loses a required ancestor.
  pure def everyEdgeNeeded(g: Graph): bool = {
    val need = requiredAncestry(g)
    g.scope.forall(v => g.parents.get(v).forall(p => {
      val rest = g.parents.get(v).exclude(Set(p))
      val cut = withParents(g, g.parents.set(v, rest))
      rest == Set() or not(need.subseteq(ancestry(cut)))
    }))
  }

  // ---------------------------------------------------------------------
  // Contract hoisting (Pass 2)
  // ---------------------------------------------------------------------

  pure def contractDefs(c: Change): Set[str] = c.defs.intersect(CONTRACTS)
  pure def implDefs(c: Change): Set[str] = c.defs.exclude(CONTRACTS)
  pure def mixed(c: Change): bool = contractDefs(c) != Set() and implDefs(c) != Set()

  // A mixed change can be hoisted when its contract part does not reference
  // its own implementation; otherwise the twin would need its own child.
  pure def hoistable(c: Change): bool = mixed(c) and c.crefs.intersect(implDefs(c)) == Set()

  // Insert each hoistable change's twin between it and its parents. The twin
  // takes the contract definitions and the contract part's references and
  // files; the change keeps the rest and everything it touches, so its tree
  // and its children are unchanged.
  pure def hoist(g: Graph): Graph = {
    val hs = g.scope.filter(v => hoistable(g.info.get(v)))
    val twins = hs.map(v => TWIN.get(v))
    val parents = g.scope.union(twins).mapBy(x =>
      if (twins.contains(x)) g.parents.get(hs.filter(v => TWIN.get(v) == x).fold("", (_acc, v) => v))
      else if (hs.contains(x)) Set(TWIN.get(x))
      else g.parents.get(x))
    val info = g.scope.union(twins).mapBy(x =>
      if (twins.contains(x)) {
        val v = hs.filter(h => TWIN.get(h) == x).fold("", (_acc, h) => h)
        val c = g.info.get(v)
        { defs: contractDefs(c), refs: c.crefs, files: c.cfiles, anchor: false, crefs: c.crefs, cfiles: c.cfiles }
      } else if (hs.contains(x)) {
        val c = g.info.get(x)
        { ...c, defs: implDefs(c), crefs: Set(), cfiles: Set() }
      } else g.info.get(x))
    { scope: g.scope.union(twins), parents: parents, info: info }
  }

  // ---------------------------------------------------------------------
  // The document's own moves, for the counterexamples
  // ---------------------------------------------------------------------

  // `jj rebase -r v -o P`: v moves to P, and v's children take v's old
  // parents in place of v.
  pure def rebaseRevision(g: Graph, v: str, onto: Set[str]): Graph = {
    val old = g.parents.get(v)
    val parents = g.scope.mapBy(x =>
      if (x == v) onto
      else if (g.parents.get(x).contains(v)) g.parents.get(x).exclude(Set(v)).union(old)
      else g.parents.get(x))
    withParents(g, parents)
  }

  // `jj rebase -s v -o P`: v moves to P with its descendants.
  pure def rebaseSource(g: Graph, v: str, onto: Set[str]): Graph =
    withParents(g, g.parents.set(v, onto))

  // Every requirement the graph already satisfies.
  pure def satisfied(g: Graph, r: Set[(str, str)]): Set[(str, str)] = {
    val a = ancestry(g)
    r.filter(e => a.contains(e))
  }

  // The crawler's local moves over a fixed requirement relation `r`:
  // add a missing required parent, drop a parent another parent covers, or
  // sink a change below a parent it does not need. A move is safe when it
  // keeps the graph acyclic and loses no satisfied requirement.
  pure def safeMove(g: Graph, r: Set[(str, str)], h: Graph): bool = and {
    h.parents != g.parents,
    isAcyclic(h),
    satisfied(g, r).subseteq(satisfied(h, r)),
  }

  pure def crawlerMoves(g: Graph, r: Set[(str, str)]): Set[Graph] = {
    val adds = r.filter(e => not(ancestry(g).contains(e)))
      .map(e => withParents(g, g.parents.set(e._2, g.parents.get(e._2).union(Set(e._1)))))
    val drops = redundant(g).map(e => withParents(g, g.parents.set(e._2, g.parents.get(e._2).exclude(Set(e._1)))))
    val sinks = g.scope.map(v => g.parents.get(v).intersect(g.scope).filter(u => not(r.contains((u, v))))
      .map(u => withParents(g, g.parents.set(v, g.parents.get(v).exclude(Set(u)).union(g.parents.get(u)))))).flatten()
    adds.union(drops).union(sinks).filter(h => safeMove(g, r, h))
  }

  // ---------------------------------------------------------------------
  // State machine: generate a graph, hoist, normalize, and run the plan
  // ---------------------------------------------------------------------

  // The original graph, the hoisted graph the plan starts from, its normal
  // form, the graph jj holds as the plan runs, the changes already placed,
  // and the number of `jj rebase` commands issued.
  var original: Graph
  var hoisted: Graph
  var target: Graph
  var current: Graph
  var placed: Set[str]
  var commands: int

  // A change may have parents among earlier changes and BASES.
  pure val ALLOWED: Set[(str, str)] =
    tuples(BASES.union(COMMITS), COMMITS).filter(e =>
      BASES.contains(e._1) or POS.get(e._1) < POS.get(e._2))

  // The parent a change gets when the generator picks none: the change
  // before it, which makes the default graph a stack.
  pure def defaultParent(c: str): str = {
    val i = POS.get(c)
    if (i == 0) BASES.fold("", (acc, b) => if (acc == "" or BASE_ANC.contains((acc, b))) b else acc)
    else ORDER[i - 1]
  }

  pure def related(rel: Set[(str, str)], c: str): Set[str] =
    rel.filter(e => e._1 == c).map(e => e._2)

  pure def build(edges: Set[(str, str)], defs: Set[(str, str)], refs: Set[(str, str)],
                 files: Set[(str, str)], anchors: Set[str], crefs: Set[(str, str)],
                 cfiles: Set[(str, str)]): Graph = {
    scope: COMMITS,
    parents: COMMITS.mapBy(c => {
      val ps = edges.filter(e => e._2 == c).map(e => e._1)
      if (ps == Set()) Set(defaultParent(c)) else ps
    }),
    info: COMMITS.mapBy(c => {
      defs: related(defs, c),
      refs: related(refs, c),
      files: related(files, c),
      anchor: anchors.contains(c),
      crefs: related(crefs, c).intersect(related(refs, c)),
      cfiles: related(cfiles, c).intersect(related(files, c)),
    }),
  }

  pure val NO_PAIRS: Set[Set[(str, str)]] = Set(Set())
  pure val SYM_PAIRS: Set[Set[(str, str)]] = tuples(COMMITS, SYMS).powerset()
  pure val FILE_PAIRS: Set[Set[(str, str)]] = tuples(COMMITS, FILES).powerset()

  action init = {
    nondet edges = ALLOWED.powerset().oneOf()
    nondet defs = SYM_PAIRS.oneOf()
    nondet refs = SYM_PAIRS.oneOf()
    nondet files = FILE_PAIRS.oneOf()
    nondet anchors = COMMITS.powerset().oneOf()
    // Hoisting needs contract symbols; without any, its inputs stay empty.
    nondet crefs = (if (CONTRACTS == Set()) NO_PAIRS else SYM_PAIRS).oneOf()
    nondet cfiles = (if (CONTRACTS == Set()) NO_PAIRS else FILE_PAIRS).oneOf()
    val g = build(edges, defs, refs, files, anchors, crefs, cfiles)
    val h = hoist(g)
    all {
      original' = g,
      hoisted' = h,
      // Without a normal form there is nothing to aim for.
      target' = if (normalizable(h)) normalForm(h) else h,
      current' = h,
      placed' = Set(),
      commands' = 0,
    }
  }

  // Place a change whose normal-form parents in scope are all placed:
  // `jj rebase -s v -o P...`, skipped when its parents are already right.
  action place(v: str): bool = all {
    normalizable(hoisted),
    not(placed.contains(v)),
    target.parents.get(v).intersect(hoisted.scope).subseteq(placed),
    val onto = target.parents.get(v)
    all {
      current' = rebaseSource(current, v, onto),
      placed' = placed.union(Set(v)),
      commands' = if (current.parents.get(v) == onto) commands else commands + 1,
      original' = original,
      hoisted' = hoisted,
      target' = target,
    },
  }

  // Once every change is placed, or the graph cannot be normalized, nothing
  // happens.
  action finished = all {
    or { placed == hoisted.scope, not(normalizable(hoisted)) },
    original' = original,
    hoisted' = hoisted,
    target' = target,
    current' = current,
    placed' = placed,
    commands' = commands,
  }

  action step = any {
    nondet v = hoisted.scope.oneOf()
    place(v),
    finished,
  }

  // ---------------------------------------------------------------------
  // Invariants
  // ---------------------------------------------------------------------

  // jj never sees a cycle, and every placed change already has its final
  // parents and keeps them.
  val PlanStaysAcyclic = isAcyclic(current)
  val PlacedChangesStay = placed.forall(v => current.parents.get(v) == target.parents.get(v))
  // The plan ends on the normal form, issuing at most one command per change.
  val PlanReachesNormalForm = placed == hoisted.scope implies current.parents == target.parents
  val PlanIsShort = commands <= hoisted.scope.size()

  // A requirement cycle is exactly what makes a graph impossible to
  // normalize; otherwise the normal form is a valid jj graph.
  val CycleIffUnnormalizable = normalizable(hoisted) iff cycleMembers(hoisted) == Set()
  val NormalFormIsAcyclic = normalizable(hoisted) implies isAcyclic(target)
  val NormalFormHasParents =
    normalizable(hoisted) implies hoisted.scope.forall(v => target.parents.get(v) != Set())

  // Every requirement holds in the normal form, so it is sound.
  val NormalFormSatisfiesRequirements = normalizable(hoisted) implies
    requirements(hoisted).subseteq(ancestry(target))
  val NormalFormIsSound = normalizable(hoisted) implies sound(target)

  // Nothing is lost: each change keeps the base it was built on, and each
  // anchor keeps every ancestor, so its tree stays the same.
  val NormalFormKeepsBase = normalizable(hoisted) implies hoisted.scope.forall(v =>
    baseNeeds(hoisted, ancestry(hoisted), v).subseteq(ancestorsIn(ancestry(target), v)))
  val NormalFormKeepsAnchors = normalizable(hoisted) implies hoisted.scope.forall(v =>
    hoisted.info.get(v).anchor implies
      ancestorsIn(ancestry(hoisted), v).subseteq(ancestorsIn(ancestry(target), v)))
  // When no anchor grows, every anchor has exactly its old changes below it,
  // so its tree is the same; growth is exactly the changes it gains.
  val UngrownAnchorsKeepTheirTrees = (normalizable(hoisted) and anchorGrowth(hoisted) == Set()) implies
    hoisted.scope.forall(v => hoisted.info.get(v).anchor implies
      ancestorsIn(ancestry(target), v).intersect(hoisted.scope) == ancestorsIn(ancestry(hoisted), v).intersect(hoisted.scope))
  val AnchorGrowthIsWhatAnchorsGain = normalizable(hoisted) implies
    anchorGrowth(hoisted) == hoisted.scope.filter(h => hoisted.info.get(h).anchor).map(h =>
      ancestorsIn(ancestry(target), h).intersect(hoisted.scope).exclude(ancestorsIn(ancestry(hoisted), h)).map(x => (x, h))
    ).flatten()

  // Minimality, in both forms.
  val NormalFormIsMinimal = normalizable(hoisted) implies minimal(target)
  val NormalFormNeedsEveryEdge = normalizable(hoisted) implies everyEdgeNeeded(target)

  // The normal form is a fixed point, and `check` reports nothing on a graph
  // exactly when it is already normal.
  val NormalizingIsIdempotent = normalizable(hoisted) implies isNormal(target)
  val CheckIffNormal = and {
    violationFree(hoisted) iff isNormal(hoisted),
    violationFree(original) iff isNormal(original),
  }
  val NormalFormChecksClean = normalizable(hoisted) implies violationFree(target)

  // Hoisting leaves no hoistable change, keeps the graph acyclic, keeps every
  // original change's ancestors, and never makes a normalizable graph
  // unnormalizable.
  val HoistingSplitsEveryMixedChange = hoisted.scope.forall(v => not(hoistable(hoisted.info.get(v))))
  val HoistingKeepsAncestors = and {
    isAcyclic(hoisted),
    original.scope.forall(v =>
      ancestorsIn(ancestry(original), v).subseteq(ancestorsIn(ancestry(hoisted), v))),
  }
  val HoistingKeepsNormalizable = normalizable(original) implies normalizable(hoisted)

  // Witnesses. Each is false in some reachable state, which shows the
  // invariants above are not vacuous; the checks expect simulation to find a
  // state that violates every one of them.
  val WitnessNeverCyclic = normalizable(hoisted)
  val WitnessNeverHoists = hoisted.scope == original.scope
  val WitnessNeverMoves = not(placed == hoisted.scope and commands > 0)
  val WitnessNeverForks = normalizable(hoisted) implies hoisted.scope.forall(v =>
    ancestorsIn(ancestry(hoisted), v).subseteq(ancestorsIn(ancestry(target), v)))
  val WitnessNeverReorders = normalizable(hoisted) implies
    tuples(hoisted.scope, hoisted.scope).forall(e =>
      not(ancestry(hoisted).contains(e) and ancestry(target).contains((e._2, e._1))))
  val WitnessNeverMerges = normalizable(hoisted) implies
    hoisted.scope.forall(v => target.parents.get(v).size() <= 1)
  val WitnessAnchorsNeverGrow = anchorGrowth(hoisted) == Set()

  val Invariants = and {
    PlanStaysAcyclic,
    PlacedChangesStay,
    PlanReachesNormalForm,
    PlanIsShort,
    CycleIffUnnormalizable,
    NormalFormIsAcyclic,
    NormalFormHasParents,
    NormalFormSatisfiesRequirements,
    NormalFormIsSound,
    NormalFormKeepsBase,
    NormalFormKeepsAnchors,
    UngrownAnchorsKeepTheirTrees,
    AnchorGrowthIsWhatAnchorsGain,
    NormalFormIsMinimal,
    NormalFormNeedsEveryEdge,
    NormalizingIsIdempotent,
    CheckIffNormal,
    NormalFormChecksClean,
    HoistingSplitsEveryMixedChange,
    HoistingKeepsAncestors,
    HoistingKeepsNormalizable,
  }
}

// The document's examples, as deterministic tests.
module NormalizeExamples {
  import Normalize(
    ORDER = ["a", "b", "c", "d", "e"],
    BASES = Set("trunk"),
    BASE_ANC = Set(),
    TWIN = Map("a" -> "a~c", "b" -> "b~c", "c" -> "c~c", "d" -> "d~c", "e" -> "e~c"),
    SYMS = Set("Storage", "Network", "Engine", "db", "client", "run"),
    CONTRACTS = Set("Storage", "Network"),
    FILES = Set("types.rs", "db.rs", "client.rs", "engine.rs", "cli.rs")
  ).*

  pure def change(defs: Set[str], refs: Set[str], files: Set[str]): Change =
    { defs: defs, refs: refs, files: files, anchor: false, crefs: Set(), cfiles: Set() }

  pure def graph(parents: str -> Set[str], info: str -> Change): Graph =
    { scope: parents.keys(), parents: parents, info: info }

  // Section 3's ghost graph is already normal: types, two realizations of
  // it, the engine that wires them, and the CLI on top.
  pure val ghost: Graph = graph(
    Map(
      "a" -> Set("trunk"),
      "b" -> Set("a"),
      "c" -> Set("a"),
      "d" -> Set("b", "c"),
      "e" -> Set("d"),
    ),
    Map(
      "a" -> change(Set("Storage", "Network"), Set(), Set("types.rs")),
      "b" -> change(Set("db"), Set("Storage"), Set("db.rs")),
      "c" -> change(Set("client"), Set("Network"), Set("client.rs")),
      "d" -> change(Set("Engine"), Set("db", "client"), Set("engine.rs")),
      "e" -> change(Set("run"), Set("Engine"), Set("cli.rs")),
    ),
  )

  run ghostGraphIsNormalTest = assert(and {
    isNormal(ghost),
    violationFree(ghost),
    sound(ghost),
    minimal(ghost),
  })

  // Pattern B: the auth client was stacked on the database adapter it does
  // not use. Normalizing forks it onto the contract and merges both into the
  // engine.
  pure val falseStack: Graph = graph(
    Map(
      "a" -> Set("trunk"),
      "b" -> Set("a"),
      "c" -> Set("b"),
      "d" -> Set("c"),
    ),
    Map(
      "a" -> change(Set("Storage", "Network"), Set(), Set("types.rs")),
      "b" -> change(Set("db"), Set("Storage"), Set("db.rs")),
      "c" -> change(Set("client"), Set("Network"), Set("client.rs")),
      "d" -> change(Set("Engine"), Set("db", "client"), Set("engine.rs")),
    ),
  )

  run orthogonalForkTest = assert(and {
    unneeded(falseStack) == Set(("b", "c")),
    normalParents(falseStack) == Map(
      "a" -> Set("trunk"),
      "b" -> Set("a"),
      "c" -> Set("a"),
      "d" -> Set("b", "c"),
    ),
  })

  // Pattern D: the CLI was prototyped before the engine it calls. The engine
  // moves below it.
  pure val cliFirst: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("a")),
    Map(
      "a" -> change(Set("run"), Set("Engine"), Set("cli.rs")),
      "b" -> change(Set("Engine"), Set(), Set("engine.rs")),
    ),
  )

  run contractFirstInversionTest = assert(and {
    unsatisfied(cliFirst) == Set(("b", "a")),
    not(sound(cliFirst)),
    normalParents(cliFirst) == Map("a" -> Set("b"), "b" -> Set("trunk")),
  })

  // The same inversion is impossible when the two touch the same file: the
  // engine's diff was made on top of the CLI's.
  pure val tangled: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("a")),
    Map(
      "a" -> change(Set("run"), Set("Engine"), Set("main.rs")),
      "b" -> change(Set("Engine"), Set(), Set("main.rs")),
    ),
  )

  run requirementCycleTest = assert(and {
    cycleMembers(tangled) == Set("a", "b"),
    not(normalizable(tangled)),
  })

  // An anchor (here the working copy on top of a stack of independent
  // changes) keeps all of them, so its files on disk do not change.
  pure val workingCopy: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("a"), "c" -> Set("b")),
    Map(
      "a" -> change(Set("db"), Set(), Set("db.rs")),
      "b" -> change(Set("client"), Set(), Set("client.rs")),
      "c" -> { ...change(Set(), Set(), Set()), anchor: true },
    ),
  )

  run anchorBecomesMergeTest = assert(and {
    normalParents(workingCopy) == Map("a" -> Set("trunk"), "b" -> Set("trunk"), "c" -> Set("a", "b")),
    anchorGrowth(workingCopy) == Set(),
  })

  // The working copy (d) sits on c, which calls a without descending from
  // it. Soundness puts a below c, so the working copy gains a's files: no
  // graph keeps its tree.
  pure val unsoundUnderWorkingCopy: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("trunk"), "c" -> Set("trunk"), "d" -> Set("c")),
    Map(
      "a" -> change(Set("db"), Set(), Set("db.rs")),
      "b" -> change(Set("client"), Set(), Set("client.rs")),
      "c" -> change(Set("run"), Set("db"), Set("cli.rs")),
      "d" -> { ...change(Set(), Set(), Set()), anchor: true },
    ),
  )

  run anchorGrowthTest = assert(and {
    normalizable(unsoundUnderWorkingCopy),
    anchorGrowth(unsoundUnderWorkingCopy) == Set(("a", "d")),
    normalParents(unsoundUnderWorkingCopy).get("c") == Set("a"),
  })

  // Pass 2: a change that defines the Storage contract and its database
  // implementation is split; the client, which only needs the contract, no
  // longer waits for the implementation.
  pure val mixedChange: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("a")),
    Map(
      "a" -> { ...change(Set("Storage", "db"), Set("Storage"), Set("types.rs", "db.rs")),
               crefs: Set(), cfiles: Set("types.rs") },
      "b" -> change(Set("client"), Set("Storage"), Set("client.rs")),
    ),
  )

  run contractHoistingTest = {
    val h = hoist(mixedChange)
    assert(and {
      h.scope == Set("a", "a~c", "b"),
      h.parents.get("a~c") == Set("trunk"),
      h.parents.get("a") == Set("a~c"),
      h.info.get("a~c").defs == Set("Storage"),
      h.info.get("a").defs == Set("db"),
      normalParents(h) == Map("a~c" -> Set("trunk"), "a" -> Set("a~c"), "b" -> Set("a~c")),
    })
  }

  // Pass 3 as the document writes it: `jj rebase -r v -d "parents(u)"`
  // where v does not use u. jj fills the hole v leaves with u, so w, which
  // needs v, loses it.
  pure val chain: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("a"), "c" -> Set("b")),
    Map(
      "a" -> change(Set("db"), Set(), Set("db.rs")),
      "b" -> change(Set("client"), Set(), Set("client.rs")),
      "c" -> change(Set("Engine"), Set("client"), Set("engine.rs")),
    ),
  )

  run docSinkDropsADescendantsDependencyTest = {
    val moved = rebaseRevision(chain, "b", chain.parents.get("a"))
    assert(and {
      requirements(chain).subseteq(ancestry(chain)),
      moved.parents.get("c") == Set("a"),
      not(requirements(chain).subseteq(ancestry(moved))),
      normalParents(chain) == Map("a" -> Set("trunk"), "b" -> Set("trunk"), "c" -> Set("b")),
    })
  }

  // A crawler of local moves stops short of the normal form: w (c) needs u
  // (a) and v (b), v does not need u, and every safe move is gone while the
  // graph is still a stack.
  pure val stuck: Graph = graph(
    Map("a" -> Set("trunk"), "b" -> Set("a"), "c" -> Set("b")),
    Map(
      "a" -> change(Set("db"), Set(), Set("db.rs")),
      "b" -> change(Set("client"), Set(), Set("client.rs")),
      "c" -> change(Set("Engine"), Set("db", "client"), Set("engine.rs")),
    ),
  )

  run crawlerStopsShortTest = assert(and {
    crawlerMoves(stuck, requirements(stuck)) == Set(),
    not(isNormal(stuck)),
    normalParents(stuck) == Map("a" -> Set("trunk"), "b" -> Set("trunk"), "c" -> Set("a", "b")),
  })

  // jj-graph's plan, `jj rebase -s` in a topological order of the normal
  // form, reaches it from the same stack.
  run planReachesNormalFormTest = {
    val n = normalParents(stuck)
    val after = rebaseSource(rebaseSource(rebaseSource(stuck, "a", n.get("a")), "b", n.get("b")), "c", n.get("c"))
    assert(after.parents == n)
  }
}

// A small instance TLC explores exhaustively: every graph on three changes
// over one base, with one symbol and one file, and every order of the plan.
module NormalizeTiny {
  import Normalize(
    ORDER = ["a", "b", "c"],
    BASES = Set("trunk"),
    BASE_ANC = Set(),
    TWIN = Map("a" -> "a~c", "b" -> "b~c", "c" -> "c~c"),
    SYMS = Set("s"),
    CONTRACTS = Set(),
    FILES = Set("f")
  ).*
}

// A wider instance for random simulation: two trunk commits, contracts and
// hoisting, two files, and four changes.
module NormalizeWide {
  import Normalize(
    ORDER = ["a", "b", "c", "d"],
    BASES = Set("t0", "t1"),
    BASE_ANC = Set(("t0", "t1")),
    TWIN = Map("a" -> "a~c", "b" -> "b~c", "c" -> "c~c", "d" -> "d~c"),
    SYMS = Set("S", "x", "y"),
    CONTRACTS = Set("S"),
    FILES = Set("f", "g")
  ).*
}
