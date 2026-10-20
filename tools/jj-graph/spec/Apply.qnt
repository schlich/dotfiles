// Applying a plan as one operation, so no workspace ever sees half of it.
//
// jj-graph runs each plan command on the operation the previous command
// produced, with `--at-op` and `--no-integrate-operation`, so the commands
// build a detached chain of operations that nothing else sees. With
// `--mergiraf`, the commands after the rebases resolve conflicts with
// mergiraf and give anchors their trees back; they are commands like any
// other. It then checks the chain's last operation (the graph is the plan's
// target, no change gained a conflict, every anchor's tree and every change's
// own diff are unchanged, item by item for a change mergiraf merged) and
// integrates it with `jj op integrate`, but only while the repository's
// head operation is still the one the plan started from. A failed command, a
// failed check, or a foreign operation before the head check abandons the
// chain, which leaves the repository as it was: an unintegrated operation is
// garbage, not history.
//
// A foreign operation can still land between the head check and the
// integration. `jj op integrate` then merges the two operations instead of
// losing either; if the merge left a change divergent, jj-graph reverts its
// own operation with `jj op revert`, which keeps the foreign one. It never
// uses `jj op restore`, which would also rewind the foreign operation.
module Apply {
  // The plan's length, and how many foreign operations may land meanwhile.
  const STEPS: int
  const FOREIGN: int

  type Phase =
    | Running
    | Checked
    | HeadChecked
    | Integrated
    | Reverted
    | Abandoned

  // The operations the repository shows, oldest first: "plan" is
  // jj-graph's integrated chain, "revert" its revert, "foreign" anyone else's.
  var visible: List[str]
  // Commands run on the detached chain, and whether every one succeeded.
  var chain: int
  var commandsOk: bool
  // Whether the check passed, and the visible length when the head was
  // checked (-1 before).
  var checkOk: bool
  var headAt: int
  // Whether integrating merged with a foreign operation and left a change
  // divergent.
  var divergent: bool
  var phase: Phase
  var foreignCount: int

  pure def count(l: List[str], x: str): int = l.foldl(0, (n, y) => if (y == x) n + 1 else n)

  action init = all {
    visible' = [],
    chain' = 0,
    commandsOk' = true,
    checkOk' = false,
    headAt' = -1,
    divergent' = false,
    phase' = Running,
    foreignCount' = 0,
  }

  // One command on the detached chain; jj may refuse it.
  action runCommand = {
    nondet ok = Set(true, false).oneOf()
    all {
      phase == Running,
      chain < STEPS,
      chain' = chain + 1,
      commandsOk' = ok,
      phase' = if (ok) Running else Abandoned,
      visible' = visible,
      checkOk' = checkOk,
      headAt' = headAt,
      divergent' = divergent,
      foreignCount' = foreignCount,
    }
  }

  // Check the chain's last operation.
  action check = {
    nondet ok = Set(true, false).oneOf()
    all {
      phase == Running,
      chain == STEPS,
      checkOk' = ok,
      phase' = if (ok) Checked else Abandoned,
      visible' = visible,
      chain' = chain,
      commandsOk' = commandsOk,
      headAt' = headAt,
      divergent' = divergent,
      foreignCount' = foreignCount,
    }
  }

  // Integrate only while nothing else has happened since the plan started.
  action checkHead = all {
    phase == Checked,
    headAt' = visible.length(),
    phase' = if (count(visible, "foreign") == 0) HeadChecked else Abandoned,
    visible' = visible,
    chain' = chain,
    commandsOk' = commandsOk,
    checkOk' = checkOk,
    divergent' = divergent,
    foreignCount' = foreignCount,
  }

  // `jj op integrate`: merges with any operation that landed after the head
  // check, which may leave a change divergent.
  action integrate = {
    nondet split = Set(true, false).oneOf()
    val raced = visible.length() > headAt
    all {
      phase == HeadChecked,
      visible' = visible.append("plan"),
      divergent' = (raced and split),
      phase' = Integrated,
      chain' = chain,
      commandsOk' = commandsOk,
      checkOk' = checkOk,
      headAt' = headAt,
      foreignCount' = foreignCount,
    }
  }

  // After integrating, jj-graph looks for divergent changes and reverts its
  // own operation if there are any.
  action revert = all {
    phase == Integrated,
    divergent,
    visible' = visible.append("revert"),
    divergent' = false,
    phase' = Reverted,
    chain' = chain,
    commandsOk' = commandsOk,
    checkOk' = checkOk,
    headAt' = headAt,
    foreignCount' = foreignCount,
  }

  // Anyone else may run an operation at any time.
  action foreign = all {
    foreignCount < FOREIGN,
    visible' = visible.append("foreign"),
    foreignCount' = foreignCount + 1,
    chain' = chain,
    commandsOk' = commandsOk,
    checkOk' = checkOk,
    headAt' = headAt,
    divergent' = divergent,
    phase' = phase,
  }

  action idle = all {
    visible' = visible,
    chain' = chain,
    commandsOk' = commandsOk,
    checkOk' = checkOk,
    headAt' = headAt,
    divergent' = divergent,
    phase' = phase,
    foreignCount' = foreignCount,
  }

  action step = any { runCommand, check, checkHead, integrate, revert, foreign, idle }

  // The plan shows up at most once, whole, and only after every command and
  // the check passed.
  val PlanAppearsWhole = count(visible, "plan") <= 1
  val OnlyCheckedPlansLand = count(visible, "plan") == 1 implies and {
    chain == STEPS,
    commandsOk,
    checkOk,
  }
  // An abandoned plan leaves no trace.
  val AbandonLeavesNoTrace = phase == Abandoned implies count(visible, "plan") == 0
  // Foreign operations are never lost: every one stays visible.
  val ForeignWorkKept = count(visible, "foreign") == foreignCount
  // A plan integrated with no foreign operation racing it cannot diverge;
  // one that did is reverted before jj-graph finishes.
  val DivergenceOnlyFromRace = divergent implies visible.length() > headAt + 1
  val RevertOnlyOwnPlan = count(visible, "revert") <= count(visible, "plan")

  val Invariants = and {
    PlanAppearsWhole,
    OnlyCheckedPlansLand,
    AbandonLeavesNoTrace,
    ForeignWorkKept,
    DivergenceOnlyFromRace,
    RevertOnlyOwnPlan,
  }

  // Liveness: with fair scheduling of jj-graph's own steps, every run
  // settles, and a divergent integration is always reverted.
  temporal Settles = (
    weakFair(runCommand, (visible, chain, commandsOk, checkOk, headAt, divergent, phase, foreignCount))
    and weakFair(check, (visible, chain, commandsOk, checkOk, headAt, divergent, phase, foreignCount))
    and weakFair(checkHead, (visible, chain, commandsOk, checkOk, headAt, divergent, phase, foreignCount))
    and weakFair(integrate, (visible, chain, commandsOk, checkOk, headAt, divergent, phase, foreignCount))
    and weakFair(revert, (visible, chain, commandsOk, checkOk, headAt, divergent, phase, foreignCount))
  ) implies eventually(always(not(divergent)) and (phase == Integrated or phase == Reverted or phase == Abandoned))
}

module ApplyBounded {
  import Apply(STEPS = 3, FOREIGN = 2).*
}
