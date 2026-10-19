// Materializing a ghost graph: the guide's Section 3, Step 2, where a
// component diagram becomes a graph of empty changes before any code exists,
// together with the behaviour it must have, written as Gherkin features.
//
// jj-graph reads a Graphviz digraph: each node becomes an empty change whose
// description is the node's label, and each edge `A -> B` makes A a parent
// of B. A diagram with a cycle is refused. An edge that another path already implies is dropped, since the
// change graph is a transitive reduction (the guide's minimality). Roots go
// onto a base revision, by default `trunk()`.
//
// Each Gherkin feature becomes a spec change at the root that adds the
// feature file: an executable specification is a contract, and contracts
// come first. Each of its scenarios becomes a change on top of the spec and
// of the components it needs, which `@needs:<node>` tags on the scenario, its
// rule, or its feature name. A scenario without such tags needs the
// diagram's sinks, its surface layer.
//
// A rerun converges instead of duplicating. A node reuses the change a
// previous run made for it: the mutable change with its title (the
// description's first line) whose parents are the node's parents. A reused
// change gets the node's current description and, for a spec, its current
// feature file; anything else in it, such as code written since, stays.
module Skeleton {
  const COMPONENTS: Set[str]
  const FEATURES: Set[str]
  // Each scenario and the feature it belongs to.
  const SCENARIO_OF: str -> str

  pure val SCENARIOS: Set[str] = SCENARIO_OF.keys()
  pure val NODES: Set[str] = COMPONENTS.union(FEATURES).union(SCENARIOS)
  pure val ONTO = "trunk"

  // A change a previous run left behind: its parents, whether its
  // description and (for a spec) its feature file are out of date, and
  // whether someone has written code in it since.
  type Existing = { parents: Set[str], staleBody: bool, staleFile: bool, populated: bool }

  // What a change holds once this run is done with it.
  type Made = { parents: Set[str], staleBody: bool, staleFile: bool, populated: bool }

  var diagram: Set[(str, str)]
  var needs: str -> Set[str]
  var existing: str -> Existing
  var made: str -> Made
  var created: int
  var updated: int
  var refused: bool

  pure def closure(r: Set[(str, str)]): Set[(str, str)] =
    NODES.fold(r, (acc, k) => {
      val into = acc.filter(e => e._2 == k).map(e => e._1)
      val outOf = acc.filter(e => e._1 == k).map(e => e._2)
      acc.union(into.map(i => outOf.map(j => (i, j))).flatten())
    })

  pure def acyclic(r: Set[(str, str)]): bool = closure(r).forall(e => e._1 != e._2)

  // The diagram's components that no other component builds on.
  pure def sinks(d: Set[(str, str)]): Set[str] =
    COMPONENTS.filter(c => not(d.exists(e => e._1 == c)))

  // Every edge: the diagram's, each feature's spec under its scenarios, and
  // each scenario's needs (the sinks when it names none).
  pure def edges(d: Set[(str, str)], n: str -> Set[str]): Set[(str, str)] = {
    val specs = SCENARIOS.map(s => (SCENARIO_OF.get(s), s))
    val used = SCENARIOS.map(s => (if (n.get(s) == Set()) sinks(d) else n.get(s)).map(c => (c, s))).flatten()
    d.union(specs).union(used)
  }

  // The edges without those another path implies.
  pure def reduction(r: Set[(str, str)]): Set[(str, str)] = {
    val c = closure(r)
    r.filter(e => not(NODES.exists(m => c.contains((e._1, m)) and c.contains((m, e._2)))))
  }

  // The parents a node's change gets.
  pure def parentsFor(r: Set[(str, str)], v: str): Set[str] = {
    val ps = reduction(r).filter(e => e._2 == v).map(e => e._1)
    if (ps == Set()) Set(ONTO) else ps
  }

  pure def built(m: str -> Made, v: str): bool = m.keys().contains(v)

  action init = {
    nondet d = tuples(COMPONENTS, COMPONENTS).filter(e => e._1 != e._2).powerset().oneOf()
    nondet n = SCENARIOS.setOfMaps(COMPONENTS.powerset()).oneOf()
    // A previous run built a downward-closed set of nodes; since then the
    // features may have changed, and code may have been written.
    nondet prior = NODES.powerset().oneOf()
    nondet staleBody = NODES.powerset().oneOf()
    nondet staleFile = FEATURES.powerset().oneOf()
    nondet populated = COMPONENTS.union(SCENARIOS).powerset().oneOf()
    val r = edges(d, n)
    val done = prior.filter(v => reduction(r).forall(e => e._2 == v implies prior.contains(e._1)))
    all {
      diagram' = d,
      needs' = n,
      existing' = if (acyclic(r)) done.mapBy(v => {
        parents: parentsFor(r, v),
        staleBody: staleBody.contains(v),
        staleFile: staleFile.contains(v),
        populated: populated.contains(v),
      }) else Map(),
      made' = Map(),
      created' = 0,
      updated' = 0,
      refused' = not(acyclic(r)),
    }
  }

  // Build a node once all its parents are built: reuse the change a
  // previous run made for it, bringing its description and feature file up
  // to date, or create it.
  action build(v: str): bool = all {
    not(refused),
    not(built(made, v)),
    reduction(edges(diagram, needs)).filter(e => e._2 == v).forall(e => built(made, e._1)),
    val ps = parentsFor(edges(diagram, needs), v)
    val reuse = existing.keys().contains(v) and existing.get(v).parents == ps
    val stale = reuse and (existing.get(v).staleBody or existing.get(v).staleFile)
    all {
      made' = made.put(v, {
        parents: ps,
        staleBody: false,
        staleFile: false,
        populated: reuse and existing.get(v).populated,
      }),
      created' = if (reuse) created else created + 1,
      updated' = if (stale) updated + 1 else updated,
      diagram' = diagram,
      needs' = needs,
      existing' = existing,
      refused' = refused,
    },
  }

  action idle = all {
    diagram' = diagram,
    needs' = needs,
    existing' = existing,
    made' = made,
    created' = created,
    updated' = updated,
    refused' = refused,
  }

  action step = any {
    nondet v = NODES.oneOf()
    build(v),
    idle,
  }

  pure def done(m: str -> Made): bool = m.keys() == NODES

  val RefusesCycles = refused iff not(acyclic(edges(diagram, needs)))
  val RefusedBuildsNothing = refused implies made.keys() == Set()
  // Every change is built after its parents, with exactly the parents the
  // reduced graph gives it.
  val ParentsComeFirst =
    made.keys().forall(v => made.get(v).parents.forall(p => p == ONTO or built(made, p)))
  val ParentsMatchGraph =
    made.keys().forall(v => made.get(v).parents == parentsFor(edges(diagram, needs), v))
  // A finished run's graph is the transitive reduction of every edge.
  val FinishedGraphIsReduction = (not(refused) and done(made)) implies
    made.keys().map(v => made.get(v).parents.exclude(Set(ONTO)).map(p => (p, v))).flatten()
      == reduction(edges(diagram, needs))
  // Specs come first: a feature's change sits only on the base.
  val SpecsAreRoots = FEATURES.forall(f => built(made, f) implies made.get(f).parents == Set(ONTO))
  // A scenario sits on its spec, or on something that already is.
  val ScenariosFollowTheirSpecs = SCENARIOS.forall(s => built(made, s) implies
    closure(reduction(edges(diagram, needs))).contains((SCENARIO_OF.get(s), s)))
  // A scenario descends from every component it needs, and with no needs
  // named, from every sink of the diagram.
  val ScenariosReachWhatTheyNeed = SCENARIOS.forall(s => built(made, s) implies {
    val want = if (needs.get(s) == Set()) sinks(diagram) else needs.get(s)
    want.forall(c => closure(reduction(edges(diagram, needs))).contains((c, s)))
  })
  // Nothing built is out of date, and code written in a reused change stays.
  val BuiltIsCurrent = made.keys().forall(v => not(made.get(v).staleBody) and not(made.get(v).staleFile))
  val WrittenCodeStays = made.keys().forall(v =>
    (existing.keys().contains(v) and existing.get(v).parents == made.get(v).parents
      and existing.get(v).populated) implies made.get(v).populated)
  // Reuse makes runs converge: only nodes no previous run built are
  // created, and only out-of-date reused ones are updated, so a second run
  // changes nothing.
  val CreatesOnlyMissing = created == made.keys().filter(v => not(existing.keys().contains(v))).size()
  val UpdatesOnlyStale = updated == made.keys().filter(v =>
    existing.keys().contains(v) and (existing.get(v).staleBody or existing.get(v).staleFile)).size()

  val Invariants = and {
    RefusesCycles,
    RefusedBuildsNothing,
    ParentsComeFirst,
    ParentsMatchGraph,
    FinishedGraphIsReduction,
    SpecsAreRoots,
    ScenariosFollowTheirSpecs,
    ScenariosReachWhatTheyNeed,
    BuiltIsCurrent,
    WrittenCodeStays,
    CreatesOnlyMissing,
    UpdatesOnlyStale,
  }

  // Witnesses: each is false in some reachable state.
  val WitnessNeverReuses = made.keys().forall(v => not(existing.keys().contains(v)))
  val WitnessNeverUpdates = updated == 0
  val WitnessNeverUsesSinks = SCENARIOS.forall(s => needs.get(s) != Set())
  val WitnessNeverDropsAnEdge = reduction(edges(diagram, needs)) == edges(diagram, needs)
}

module SkeletonExamples {
  import Skeleton(
    COMPONENTS = Set("types", "db", "client", "engine", "cli"),
    FEATURES = Set("login"),
    SCENARIO_OF = Map("ok" -> "login", "locked" -> "login")
  ).*

  // The guide's diagram, with one redundant edge added: types --> engine is
  // implied by types --> db --> engine.
  pure val guide = Set(
    ("types", "db"),
    ("types", "client"),
    ("db", "engine"),
    ("client", "engine"),
    ("engine", "cli"),
    ("types", "engine"),
  )

  run guideDiagramTest = assert(and {
    acyclic(guide),
    reduction(guide) == guide.exclude(Set(("types", "engine"))),
    parentsFor(guide, "types") == Set(ONTO),
    parentsFor(guide, "engine") == Set("db", "client"),
  })

  run cycleRefusedTest = assert(not(acyclic(guide.union(Set(("cli", "types"))))))

  // A scenario that names no components lands on the surface layer (the
  // CLI); one that needs the engine and the CLI keeps only the CLI, which
  // already builds on the engine. Both sit on their feature's spec, which
  // sits on the base.
  run scenariosLandOnWhatTheyNeedTest = {
    val r = edges(guide, Map("ok" -> Set(), "locked" -> Set("engine", "cli")))
    assert(and {
      sinks(guide) == Set("cli"),
      parentsFor(r, "login") == Set(ONTO),
      parentsFor(r, "ok") == Set("login", "cli"),
      parentsFor(r, "locked") == Set("login", "cli"),
    })
  }
}

module SkeletonSmall {
  import Skeleton(
    COMPONENTS = Set("a", "b"),
    FEATURES = Set("f"),
    SCENARIO_OF = Map("s" -> "f")
  ).*
}

module SkeletonWide {
  import Skeleton(
    COMPONENTS = Set("a", "b", "c"),
    FEATURES = Set("f", "g"),
    SCENARIO_OF = Map("s" -> "f", "t" -> "f", "u" -> "g")
  ).*
}
