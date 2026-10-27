--------------------------- MODULE StagedSwitch ---------------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************)
(* The staged switch in deploy/switch.nu and the processes that race it.   *)
(*                                                                         *)
(* Every entry point of switch.nu takes the state directory's flock        *)
(* itself: a switch (manual or the canary's --auto), the dead-man timer's *)
(* `main revert`, and the boot-time `main settle`. A switch stages a       *)
(* revision step by step: settle what a dead run left, re-arm the dead-man *)
(* timer, write pending.nuon, activate the candidate without making it the *)
(* boot default, watch it, then commit it or revert to the system it       *)
(* replaced. The dead-man timer fires into a transient unit that waits for *)
(* the lock, so it settles a stage only once the run that armed it has    *)
(* died; a run that disarms it stops that unit too. Either process can be *)
(* killed, and a reboot kills both, drops the transient timer, boots the  *)
(* boot default, and starts the boot-time settle. Files in the state      *)
(* directory survive all of that.                                         *)
(*                                                                         *)
(* Settling reads pending.nuon under the lock, so no live run owns it. A  *)
(* stage that reached the system profile finishes its commit; any other   *)
(* is rejected, and the host returns to the boot default if it is not     *)
(* running it.                                                            *)
(*                                                                         *)
(* Each step below is one action of switch.nu, in its order, and reads or *)
(* writes only what that line does: the processes interleave between      *)
(* them. Every candidate is the system of one revision, so a revision     *)
(* stands for its candidate. The watch is one step that reads the running *)
(* system's health; sampling and strikes are left out. Building,         *)
(* evaluating, and the dry-activate preview only reject a revision before *)
(* anything runs, so they are left out too, as are the report and         *)
(* generation logs, which no step reads back. The dead-man and the        *)
(* boot-time settle share one process here: each settles under the lock, *)
(* and a run stops a waiting one only after settling first itself.        *)
(*                                                                         *)
(* The dead-man timer fires duration + grace after it is armed. Arming    *)
(* comes before activation, which has no timeout, so with SlowActivation  *)
(* the timer may fire at any time while armed. Without it, the timer      *)
(* fires only once the run that armed it has died, as the design intends. *)
(***************************************************************************)

CONSTANTS
    Initial,        \* the system the host runs before any switch
    Revs,           \* revisions of main, each with its own candidate
    MaxStages,      \* bound on staged switches, to keep the model finite
    AutoDeploy,     \* whether the canary timer runs `--auto`
    SlowActivation  \* whether activation can outlast the grace period

ASSUME Initial \notin Revs /\ Revs # {} /\ MaxStages \in Nat

Systems == {Initial} \cup Revs
Stages == 0..MaxStages
Who == {"switch", "settle", "deadman"}

(* pending.nuon, or a settle's copy of it. Stage 0 is no file. *)
Pending == [stage : Stages, rev : Systems, prev : Systems]
NoPending == [stage |-> 0, rev |-> Initial, prev |-> Initial]

(* The dead-man's states that hold the lock. *)
Holding == {"read", "finish", "restore", "reject", "clear"}

VARIABLES
    current,     \* /run/current-system
    boot,        \* the system profile and boot loader default
    healthy,     \* which systems pass the watch; fixed in each behaviour
    pending,     \* pending.nuon
    timer,       \* the dead-man timer is armed
    timerStage,  \* the stage whose run armed it
    pcS,         \* the switch process; it holds the lock unless "idle"
    run,         \* that process's locals: its stage, revision, previous
                 \* system, and whether it runs --auto
    pcD,         \* the dead-man or boot-time settle; it holds the lock in
                 \* Holding and waits for it in "wait"
    seen,        \* the pending record the settling process read
    mainRev,     \* Tangled's main
    landed,      \* every revision main has held
    last,        \* last.nuon's revision
    rejected,    \* rejected.nuon
    stage,       \* staged switches so far
    passed,      \* candidates whose watch passed while they ran (history)
    committed,   \* stages made the boot default (history)
    reverted,    \* <<stage, process>> pairs that reactivated a system for a
                 \* stage (history)
    autoStaged   \* activations of each revision by `--auto` (history)

vars == <<current, boot, healthy, pending, timer, timerStage, pcS, run, pcD,
          seen, mainRev, landed, last, rejected, stage, passed, committed,
          reverted, autoStaged>>

world == <<healthy, mainRev, landed>>
history == <<passed, committed, reverted, autoStaged>>

Run == [stage : Stages, rev : Systems, prev : Systems, auto : BOOLEAN]

Init ==
    /\ current = Initial
    /\ boot = Initial
    /\ healthy \in [Systems -> BOOLEAN]
    /\ healthy[Initial]
    /\ pending = NoPending
    /\ timer = FALSE
    /\ timerStage = 0
    /\ pcS = "idle"
    /\ run = [stage |-> 0, rev |-> Initial, prev |-> Initial, auto |-> FALSE]
    /\ pcD = "idle"
    /\ seen = NoPending
    /\ mainRev \in Revs
    /\ landed = {mainRev}
    /\ last = Initial
    /\ rejected = {}
    /\ stage = 0
    /\ passed = {}
    /\ committed = {}
    /\ reverted = {}
    /\ autoStaged = [r \in Revs |-> 0]

(* A switch step: the process moves from `from` to `to`. *)
Step(from, to) == pcS = from /\ pcS' = to

AsPending(r) == [stage |-> r.stage, rev |-> r.rev, prev |-> r.prev]

(* disarm-deadman: stop the timer and a dead-man waiting for the lock. *)
StopDeadman ==
    /\ timer' = FALSE
    /\ pcD' = IF pcD = "wait" THEN "idle" ELSE pcD

(***************************************************************************)
(* Settling a dead run's stage                                             *)
(***************************************************************************)

(* What `settle` does with the pending record `p`. *)
SettleStep(p) ==
    IF p = NoPending THEN "done"
    ELSE IF boot = p.rev THEN "finish"
    ELSE IF current # boot THEN "restore"
    ELSE "reject"

(***************************************************************************)
(* The switch process                                                      *)
(***************************************************************************)

(* relock: `main` runs again under the flock; `--auto` gives way to a     *)
(* holder, and a manual switch waits for it.                              *)
Begin(auto) ==
    /\ pcS = "idle"
    /\ pcD \notin Holding
    /\ pcS' = "settleRead"
    /\ run' = [run EXCEPT !.auto = auto]
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, pcD, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

StartManual == Begin(FALSE)
StartAuto == AutoDeploy /\ Begin(TRUE)

SwitchSettlePc ==
    [done |-> "resolve", finish |-> "settleFinish", restore |-> "settleRestore",
     reject |-> "settleReject"]

(* settle: read pending.nuon, the system profile, and the running system. *)
SettleRead ==
    /\ pcS = "settleRead"
    /\ seen' = pending
    /\ pcS' = SwitchSettlePc[SettleStep(pending)]
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* settle: the stage reached the system profile; `switch-to-configuration *)
(* boot` finishes its commit.                                             *)
SettleFinish ==
    /\ Step("settleFinish", "settleClear")
    /\ committed' = committed \cup {seen.stage}
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   last, rejected, stage, passed, reverted, autoStaged>>
    /\ UNCHANGED world

(* settle: reactivate the system profile. *)
SettleRestore ==
    /\ Step("settleRestore", "settleReject")
    /\ current' = boot
    /\ reverted' = reverted \cup {<<seen.stage, "settle">>}
    /\ UNCHANGED <<boot, pending, timer, timerStage, run, pcD, seen, last,
                   rejected, stage, passed, committed, autoStaged>>
    /\ UNCHANGED world

(* settle: record-revert appends the revision to rejected.nuon. *)
SettleReject ==
    /\ Step("settleReject", "settleClear")
    /\ rejected' = rejected \cup {seen.rev}
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   last, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

SettleClear ==
    /\ Step("settleClear", "resolve")
    /\ pending' = NoPending
    /\ UNCHANGED <<current, boot, timer, timerStage, run, pcD, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* main: resolve main, then stage it unless --auto already handled it or *)
(* it already runs. `active` is read once, here.                          *)
Resolve ==
    /\ pcS = "resolve"
    /\ IF run.auto /\ (mainRev = last \/ mainRev \in rejected)
       THEN /\ pcS' = "idle"
            /\ UNCHANGED <<last, run, stage>>
       ELSE IF mainRev = current
       THEN /\ pcS' = "idle"
            /\ last' = mainRev
            /\ UNCHANGED <<run, stage>>
       ELSE IF stage = MaxStages
       THEN /\ pcS' = "idle"
            /\ UNCHANGED <<last, run, stage>>
       ELSE /\ pcS' = "disarm"
            /\ stage' = stage + 1
            /\ run' = [stage |-> stage + 1, rev |-> mainRev, prev |-> current,
                       auto |-> run.auto]
            /\ UNCHANGED last
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, pcD, seen,
                   rejected>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* arm-deadman: disarm-deadman first. *)
ArmDisarm ==
    /\ Step("disarm", "arm")
    /\ StopDeadman
    /\ UNCHANGED <<current, boot, pending, timerStage, run, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* arm-deadman: `systemd-run --unit nixos-switch-main-deadman` fails while *)
(* a dead-man service of that name still runs, and the error ends the run. *)
Arm ==
    /\ pcS = "arm"
    /\ IF pcD = "idle"
       THEN /\ timer' = TRUE
            /\ timerStage' = run.stage
            /\ pcS' = "save"
       ELSE /\ pcS' = "idle"
            /\ UNCHANGED <<timer, timerStage>>
    /\ UNCHANGED <<current, boot, pending, run, pcD, seen, last, rejected,
                   stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* stage: `$pending | to nuon | save --force $file`, right before the     *)
(* activation it stands for.                                              *)
Save ==
    /\ Step("save", "activate")
    /\ pending' = AsPending(run)
    /\ UNCHANGED <<current, boot, timer, timerStage, run, pcD, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* `switch-to-configuration test` *)
Activate ==
    /\ Step("activate", "saveActivated")
    /\ current' = run.rev
    /\ autoStaged' = IF run.auto
                     THEN [autoStaged EXCEPT ![run.rev] = @ + 1]
                     ELSE autoStaged
    /\ UNCHANGED <<boot, pending, timer, timerStage, run, pcD, seen, last,
                   rejected, stage, passed, committed, reverted>>
    /\ UNCHANGED world

(* `$pending | insert activated ... | save --force $file` *)
SaveActivated ==
    /\ Step("saveActivated", "watch")
    /\ pending' = AsPending(run)
    /\ UNCHANGED <<current, boot, timer, timerStage, run, pcD, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* watch: samples whatever system is running. *)
Watch ==
    /\ pcS = "watch"
    /\ IF healthy[current]
       THEN /\ pcS' = "commitCheck"
            /\ passed' = IF current = run.rev THEN passed \cup {run.rev} ELSE passed
       ELSE /\ pcS' = "revertActivate"
            /\ UNCHANGED passed
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   last, rejected, stage, committed, reverted, autoStaged>>
    /\ UNCHANGED world

(* commit: `if (active) != $pending.candidate or not ($file | path exists)` *)
(* raises an error, which ends the run without saving last.nuon.          *)
CommitCheck ==
    /\ pcS = "commitCheck"
    /\ pcS' = IF current # run.rev \/ pending = NoPending THEN "idle" ELSE "commitBoot"
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   last, rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* commit: `nix-env --set` and `switch-to-configuration boot` *)
CommitBoot ==
    /\ Step("commitBoot", "commitClear")
    /\ boot' = run.rev
    /\ committed' = committed \cup {run.stage}
    /\ UNCHANGED <<current, pending, timer, timerStage, run, pcD, seen, last,
                   rejected, stage, passed, reverted, autoStaged>>
    /\ UNCHANGED world

(* commit: `rm --force $file` *)
CommitClear ==
    /\ Step("commitClear", "commitDisarm")
    /\ pending' = NoPending
    /\ UNCHANGED <<current, boot, timer, timerStage, run, pcD, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* commit: disarm-deadman, once nothing is left for it to settle. A       *)
(* dead-man that fired meanwhile has waited for the lock, and a run killed *)
(* before this step leaves it armed.                                      *)
CommitDisarm ==
    /\ Step("commitDisarm", "commitLast")
    /\ StopDeadman
    /\ UNCHANGED <<current, boot, pending, timerStage, run, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* main: save-last, outcome deployed *)
CommitLast ==
    /\ Step("commitLast", "idle")
    /\ last' = run.rev
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* restore: the previous system's `switch-to-configuration test` *)
RevertActivate ==
    /\ Step("revertActivate", "revertRecord")
    /\ current' = run.prev
    /\ reverted' = reverted \cup {<<run.stage, "switch">>}
    /\ UNCHANGED <<boot, pending, timer, timerStage, run, pcD, seen, last,
                   rejected, stage, passed, committed, autoStaged>>
    /\ UNCHANGED world

(* record-revert: appends the revision to rejected.nuon *)
RevertRecord ==
    /\ Step("revertRecord", "revertClear")
    /\ rejected' = rejected \cup {run.rev}
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   last, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* restore: `rm --force $file` *)
RevertClear ==
    /\ Step("revertClear", "revertDisarm")
    /\ pending' = NoPending
    /\ UNCHANGED <<current, boot, timer, timerStage, run, pcD, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* revert: disarm-deadman, once the revert is recorded and cleared. *)
RevertDisarm ==
    /\ Step("revertDisarm", "revertLast")
    /\ StopDeadman
    /\ UNCHANGED <<current, boot, pending, timerStage, run, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* main: save-last, outcome reverted *)
RevertLast ==
    /\ Step("revertLast", "idle")
    /\ last' = run.rev
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* The process dies at any step, and the flock goes with it. *)
KillSwitch ==
    /\ pcS # "idle"
    /\ pcS' = "idle"
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, run, pcD, seen,
                   last, rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(***************************************************************************)
(* The dead-man and the boot-time settle: `main revert`, `main settle`     *)
(***************************************************************************)

Fire ==
    /\ timer
    /\ pcD = "idle"
    /\ SlowActivation \/ pcS = "idle" \/ run.stage # timerStage
    /\ timer' = FALSE
    /\ pcD' = "wait"
    /\ UNCHANGED <<current, boot, pending, timerStage, pcS, run, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* relock: the flock is free. *)
Acquire ==
    /\ pcD = "wait"
    /\ pcS = "idle"
    /\ pcD' = "read"
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, pcS, run, seen,
                   last, rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

DeadmanSettlePc ==
    [done |-> "idle", finish |-> "finish", restore |-> "restore",
     reject |-> "reject"]

DeadmanRead ==
    /\ pcD = "read"
    /\ seen' = pending
    /\ pcD' = DeadmanSettlePc[SettleStep(pending)]
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, pcS, run, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

DeadmanFinish ==
    /\ pcD = "finish"
    /\ pcD' = "clear"
    /\ committed' = committed \cup {seen.stage}
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, pcS, run, seen,
                   last, rejected, stage, passed, reverted, autoStaged>>
    /\ UNCHANGED world

DeadmanRestore ==
    /\ pcD = "restore"
    /\ pcD' = "reject"
    /\ current' = boot
    /\ reverted' = reverted \cup {<<seen.stage, "deadman">>}
    /\ UNCHANGED <<boot, pending, timer, timerStage, pcS, run, seen, last,
                   rejected, stage, passed, committed, autoStaged>>
    /\ UNCHANGED world

DeadmanReject ==
    /\ pcD = "reject"
    /\ pcD' = "clear"
    /\ rejected' = rejected \cup {seen.rev}
    /\ UNCHANGED <<current, boot, pending, timer, timerStage, pcS, run, seen,
                   last, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

DeadmanClear ==
    /\ pcD = "clear"
    /\ pcD' = "idle"
    /\ pending' = NoPending
    /\ UNCHANGED <<current, boot, timer, timerStage, pcS, run, seen, last,
                   rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(***************************************************************************)
(* The world                                                               *)
(***************************************************************************)

(* Power loss, a panic, or a candidate that hangs the host. The boot-time *)
(* settle then waits for the lock.                                        *)
Reboot ==
    /\ current' = boot
    /\ pcS' = "idle"
    /\ pcD' = "wait"
    /\ timer' = FALSE
    /\ UNCHANGED <<boot, pending, timerStage, run, seen, last, rejected, stage>>
    /\ UNCHANGED world
    /\ UNCHANGED history

(* `ci land` moves main forward, never back to a revision it held. *)
MainMoves ==
    /\ \E r \in Revs \ landed : mainRev' = r /\ landed' = landed \cup {r}
    /\ UNCHANGED <<current, boot, healthy, pending, timer, timerStage, pcS, run,
                   pcD, seen, last, rejected, stage>>
    /\ UNCHANGED history

Next ==
    \/ StartManual \/ StartAuto
    \/ SettleRead \/ SettleFinish \/ SettleRestore \/ SettleReject \/ SettleClear
    \/ Resolve \/ ArmDisarm \/ Arm \/ Save \/ Activate \/ SaveActivated \/ Watch
    \/ CommitDisarm \/ CommitCheck \/ CommitBoot \/ CommitClear \/ CommitLast
    \/ RevertDisarm \/ RevertActivate \/ RevertRecord \/ RevertClear \/ RevertLast
    \/ KillSwitch
    \/ Fire \/ Acquire \/ DeadmanRead \/ DeadmanFinish \/ DeadmanRestore
    \/ DeadmanReject \/ DeadmanClear
    \/ Reboot \/ MainMoves

Spec == Init /\ [][Next]_vars

(***************************************************************************)
(* Properties                                                              *)
(***************************************************************************)

TypeOK ==
    /\ current \in Systems
    /\ boot \in Systems
    /\ healthy \in [Systems -> BOOLEAN]
    /\ pending \in Pending
    /\ timer \in BOOLEAN
    /\ timerStage \in Stages
    /\ pcS \in {"idle", "settleRead", "settleFinish", "settleRestore",
                "settleReject", "settleClear", "resolve", "disarm", "arm",
                "save", "activate", "saveActivated", "watch", "commitDisarm",
                "commitCheck", "commitBoot", "commitClear", "commitLast",
                "revertDisarm", "revertActivate", "revertRecord",
                "revertClear", "revertLast"}
    /\ run \in Run
    /\ pcD \in {"idle", "wait"} \cup Holding
    /\ seen \in Pending
    /\ mainRev \in Revs
    /\ landed \subseteq Revs
    /\ last \in Systems
    /\ rejected \subseteq Revs
    /\ stage \in Stages
    /\ passed \subseteq Revs
    /\ committed \subseteq Stages
    /\ reverted \subseteq Stages \X Who
    /\ autoStaged \in [Revs -> Stages]

(* Only a candidate that stayed healthy through its watch becomes the boot *)
(* default.                                                               *)
BootDefaultPassedItsWatch == boot \in {Initial} \cup passed

(* A stage either becomes the boot default or is reverted, never both:    *)
(* otherwise the host runs one system and boots another, and the revert   *)
(* log contradicts the generation log.                                    *)
CommitIsNeverReverted ==
    \A n \in committed : \A w \in Who : <<n, w>> \notin reverted

(* One revert per stage, so the revert log counts each revert once. *)
OneRevertPerStage ==
    \A n \in Stages : Cardinality({w \in Who : <<n, w>> \in reverted}) <= 1

(* Once nothing is in flight, the host runs its boot default: no          *)
(* candidate is left active without a watch or a dead-man to settle it.   *)
Settled == pcS = "idle" /\ pcD = "idle" /\ ~timer
SettledRunsBootDefault == Settled => current = boot

(* Once nothing is in flight, no pending.nuon is left to mislead          *)
(* `generation` or a later dead-man.                                      *)
SettledHasNoPending == Settled => pending = NoPending

(* The canary stages a revision at most once: a revision whose stage was   *)
(* cut short, such as by a reboot it caused, is not staged again until    *)
(* main moves.                                                            *)
AutoStagesEachRevisionOnce == \A r \in Revs : autoStaged[r] <= 1

(* A settle never runs beside a live switch, and clears only the pending  *)
(* switch it read.                                                        *)
SettleNeverRacesARun ==
    /\ pcD \in Holding => pcS = "idle"
    /\ (pcD = "clear" \/ pcS = "settleClear") => pending.stage \in {0, seen.stage}

(* A revert, by any process, restores the boot default: the system the    *)
(* host last proved healthy, not a candidate nobody watched.              *)
RevertRestoresBootDefault ==
    [][(RevertActivate \/ SettleRestore \/ DeadmanRestore) => current' = boot]_vars

=============================================================================
