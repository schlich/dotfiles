---------------------- MODULE JjCi ----------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************)
(* A bounded protocol model for the lifecycle enforced by jj/ci.nu.         *)
(*                                                                       *)
(* The model abstracts command execution and remote failures. It tracks   *)
(* only the safety-relevant facts: workspace ownership, topic readiness,  *)
(* exact published head, conflict state, the head a landing gate passed,  *)
(* the stack parent, and the trunk tip.                                   *)
(* Validation is tagged with the head it checked and the head captured at *)
(* publication, so later edits cannot blur that relationship.              *)
(*                                                                       *)
(* Landing is a fast-forward of main to the exact head a gate (the flake   *)
(* checks built locally by default, the spindle, or GitHub Actions)       *)
(* passed, pushed with a lease on the trunk the topic is based on. No     *)
(* forge merges: a squash, rebase, or merge commit would put a commit on  *)
(* main that no gate ran on.                                              *)
(*                                                                       *)
(* Ownership follows jj/codex-session.nu. A Codex task claims a workspace *)
(* at startup (a claim directory plus an ownership record), and its record *)
(* ends as delivered or discarded by finish or abandon, or as released     *)
(* when the task left its change behind and `jj-ci unclaim` frees the      *)
(* workspace. A repository with topic workspaces keeps its default one as *)
(* the canonical checkout, which no task claims.                           *)
(***************************************************************************)

CONSTANTS Heads, MainHeads, Legacy
ASSUME Heads # {} /\ MainHeads # {} /\ Heads \cap MainHeads = {}
(* Legacy = TRUE restores the behavior before ownership states existed, so  *)
(* JjCiLegacy.cfg can show each ownership invariant catches its failure.    *)
ASSUME Legacy \in BOOLEAN

OwnerStates == {"none", "active", "delivered", "discarded", "released"}

VARIABLES owner, active, head, base, conflict, validated, validatedHead,
          published, publishedHead, publishedValidated, publishedValidationHead,
          publishedConflictFree, passedHead, parentLanded, mainHead,
          landedOnto, delivered, workspaceBase,
          ownerState, claim, checkedOut, workspaceKind, dedicated

vars == <<owner, active, head, base, conflict, validated, validatedHead,
          published, publishedHead, publishedValidated, publishedValidationHead,
          publishedConflictFree, passedHead, parentLanded, mainHead,
          landedOnto, delivered, workspaceBase,
          ownerState, claim, checkedOut, workspaceKind, dedicated>>

(* Facts owned by the outside world: the gate's verdicts, the stack        *)
(* parent, and other topics landing on trunk.                             *)
worldVars == <<passedHead, parentLanded, mainHead>>

(* The ownership record, the claim directory, whether the owner's change  *)
(* is checked out in the workspace, and what kind of workspace it is.     *)
ownershipVars == <<ownerState, claim, checkedOut, workspaceKind, dedicated>>

(* Every topic variable, for actions that touch only ownership. *)
topicVars == <<head, base, conflict, validated, validatedHead, published,
               publishedHead, publishedValidated, publishedValidationHead,
               publishedConflictFree, landedOnto, delivered, workspaceBase>>

Init ==
    /\ owner = FALSE
    /\ active = FALSE
    /\ head \in Heads
    /\ base \in MainHeads
    /\ mainHead = base
    /\ conflict = FALSE
    /\ validated = FALSE
    /\ validatedHead = "none"
    /\ published = FALSE
    /\ publishedHead = "none"
    /\ publishedValidated = FALSE
    /\ publishedValidationHead = "none"
    /\ publishedConflictFree = FALSE
    /\ passedHead = "none"
    /\ landedOnto = "none"
    \* FALSE for a topic stacked on an unlanded parent.
    /\ parentLanded \in BOOLEAN
    /\ delivered = FALSE
    /\ workspaceBase = "topic"
    /\ ownerState = "none"
    /\ claim = FALSE
    /\ checkedOut = TRUE
    /\ workspaceKind \in {"default", "topic"}
    \* Whether the repository has topic workspaces besides this one.
    /\ dedicated \in BOOLEAN

(* A Codex task claims an unclaimed workspace at startup. It skips the     *)
(* canonical checkout of a repository that uses topic workspaces, and a    *)
(* leftover claim directory stops it until `jj-ci unclaim` clears it.     *)
Claim ==
    /\ ownerState = "none" /\ ~claim
    /\ (Legacy \/ ~(workspaceKind = "default" /\ dedicated))
    /\ owner' = TRUE
    /\ active' = TRUE
    /\ ownerState' = "active"
    /\ claim' = TRUE
    /\ checkedOut' = TRUE
    /\ UNCHANGED <<workspaceKind, dedicated>>
    /\ UNCHANGED topicVars
    /\ UNCHANGED worldVars

(* The workspace leaves the owner's change (`jj new` or `jj edit`) without *)
(* finish or abandon. The session guard then blocks every topic command.  *)
MoveAway ==
    /\ active /\ checkedOut
    /\ checkedOut' = FALSE
    /\ UNCHANGED <<owner, active, ownerState, claim, workspaceKind, dedicated>>
    /\ UNCHANGED topicVars
    /\ UNCHANGED worldVars

MoveBack ==
    /\ active /\ ~checkedOut
    /\ checkedOut' = TRUE
    /\ UNCHANGED <<owner, active, ownerState, claim, workspaceKind, dedicated>>
    /\ UNCHANGED topicVars
    /\ UNCHANGED worldVars

(* The guard admits topic commands only while the owner's change is       *)
(* checked out.                                                           *)
Owned == owner /\ active /\ checkedOut

Edit ==
    /\ Owned /\ ~delivered
    /\ \E h \in Heads :
         /\ head' = h
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, base, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars
    /\ UNCHANGED worldVars

(* A rebase onto the current trunk rewrites every commit in the topic, so  *)
(* the head changes too.                                                  *)
RebaseClean ==
    /\ Owned /\ ~conflict /\ ~delivered
    /\ base' = mainHead
    /\ \E h \in Heads :
         /\ head' = h
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars
    /\ UNCHANGED worldVars

RebaseConflicted ==
    /\ Owned /\ ~conflict /\ ~delivered
    /\ base' = mainHead
    /\ \E h \in Heads :
         /\ head' = h
    /\ conflict' = TRUE
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, published, publishedHead,
                   publishedValidated, publishedValidationHead, publishedConflictFree,
                   landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars
    /\ UNCHANGED worldVars

Resolve ==
    /\ Owned /\ conflict /\ ~delivered
    /\ conflict' = FALSE
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, head, base, published, publishedHead,
                   publishedValidated, publishedValidationHead, publishedConflictFree,
                   landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars
    /\ UNCHANGED worldVars

Validate ==
    /\ Owned /\ ~conflict /\ ~delivered
    /\ validated' = TRUE
    /\ validatedHead' = head
    /\ UNCHANGED <<owner, active, head, base, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars
    /\ UNCHANGED worldVars

Publish ==
    /\ Owned /\ validated /\ validatedHead = head
    /\ ~conflict /\ ~delivered
    /\ published' = TRUE
    /\ publishedHead' = head
    /\ publishedValidated' = validated
    /\ publishedValidationHead' = validatedHead
    /\ publishedConflictFree' = ~conflict
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars
    /\ UNCHANGED worldVars

(* The gate checks an exact published head (CI on every push, the local   *)
(* gate when jj-ci land runs) and passes it by commit, so a verdict never *)
(* carries over to a rewritten head. A failing run simply never passes.   *)
GatePasses ==
    /\ published
    /\ passedHead' = publishedHead
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, parentLanded, mainHead,
                   landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars

(* The stack parent lands; the child is then based on trunk. *)
ParentLands ==
    /\ ~parentLanded
    /\ parentLanded' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, passedHead, mainHead,
                   landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars

(* Another topic lands first and moves trunk. *)
TrunkAdvances ==
    /\ ~delivered
    /\ \E m \in MainHeads \ {mainHead} :
         /\ mainHead' = m
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, passedHead, parentLanded,
                   landedOnto, delivered, workspaceBase>>
    /\ UNCHANGED ownershipVars

(* jj-ci land fast-forwards main to the exact head the gate passed. The    *)
(* push carries a lease on the trunk the topic is based on, so it fails if *)
(* trunk moved, and the topic must rebase, republish, and pass again.      *)
Land ==
    /\ Owned /\ published /\ ~conflict /\ ~delivered
    /\ parentLanded
    /\ publishedHead = head
    /\ passedHead = head
    /\ base = mainHead
    /\ landedOnto' = mainHead
    /\ mainHead' = head
    /\ delivered' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, passedHead, parentLanded, workspaceBase>>
    /\ UNCHANGED ownershipVars

(* Releasing a topic leaves its workspace on main (--keep, or one that    *)
(* jj-ci start did not create) or drops it, so no workspace outlives its  *)
(* owner. The record says whether the topic was delivered.               *)
Finish ==
    /\ Owned /\ ~conflict
    /\ (delivered \/ ~published)
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ workspaceBase' \in {"main", "dropped"}
    /\ ownerState' = IF delivered THEN "delivered" ELSE "discarded"
    /\ claim' = FALSE
    /\ checkedOut' = FALSE
    /\ UNCHANGED <<head, base, conflict, validated, validatedHead, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, landedOnto, delivered>>
    /\ UNCHANGED <<workspaceKind, dedicated>>
    /\ UNCHANGED worldVars

(* Abandoning discards unpublished work, conflicts included. The model    *)
(* omits PR closure, so a published topic cannot be abandoned.            *)
Abandon ==
    /\ Owned /\ ~published
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ conflict' = FALSE
    /\ workspaceBase' \in {"main", "dropped"}
    /\ ownerState' = "discarded"
    /\ claim' = FALSE
    /\ checkedOut' = FALSE
    /\ UNCHANGED <<head, base, validated, validatedHead, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, landedOnto, delivered>>
    /\ UNCHANGED <<workspaceKind, dedicated>>
    /\ UNCHANGED worldVars

(* `jj-ci unclaim` frees a workspace whose task left its change behind. It *)
(* touches only ownership: the topic keeps its revisions, branch, and      *)
(* pipeline state, and may continue in another workspace.                 *)
Unclaim ==
    /\ owner /\ active /\ ~checkedOut
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ ownerState' = "released"
    /\ claim' = FALSE
    /\ UNCHANGED <<checkedOut, workspaceKind, dedicated>>
    /\ UNCHANGED topicVars
    /\ UNCHANGED worldVars

(* Before `jj-ci unclaim`, a stuck workspace was freed by setting          *)
(* `finished` in its record by hand. That left the claim directory, and    *)
(* every reader took `finished` for a completed topic.                    *)
HandRelease ==
    /\ Legacy
    /\ owner /\ active /\ ~checkedOut
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ ownerState' = "delivered"
    /\ UNCHANGED <<claim, checkedOut, workspaceKind, dedicated>>
    /\ UNCHANGED topicVars
    /\ UNCHANGED worldVars

Next == Claim \/ MoveAway \/ MoveBack \/ HandRelease
        \/ Edit \/ RebaseClean \/ RebaseConflicted \/ Resolve \/ Validate
        \/ Publish \/ GatePasses \/ ParentLands \/ TrunkAdvances
        \/ Land \/ Finish \/ Abandon \/ Unclaim

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ owner \in BOOLEAN
    /\ active \in BOOLEAN
    /\ head \in Heads
    /\ base \in MainHeads
    /\ conflict \in BOOLEAN
    /\ validated \in BOOLEAN
    /\ validatedHead \in Heads \cup {"none"}
    /\ published \in BOOLEAN
    /\ publishedHead \in Heads \cup {"none"}
    /\ publishedValidated \in BOOLEAN
    /\ publishedValidationHead \in Heads \cup {"none"}
    /\ publishedConflictFree \in BOOLEAN
    /\ passedHead \in Heads \cup {"none"}
    /\ parentLanded \in BOOLEAN
    /\ mainHead \in MainHeads \cup Heads
    /\ landedOnto \in MainHeads \cup {"none"}
    /\ delivered \in BOOLEAN
    /\ workspaceBase \in {"topic", "main", "dropped"}
    /\ ownerState \in OwnerStates
    /\ claim \in BOOLEAN
    /\ checkedOut \in BOOLEAN
    /\ workspaceKind \in {"default", "topic"}
    /\ dedicated \in BOOLEAN

NoPublishWhileUnsafe ==
    published => publishedHead \in Heads /\ publishedValidated /\ publishedConflictFree
PublishedHeadWasValidated == published => publishedHead = publishedValidationHead
(* Finish and abandon leave no conflict behind. A released topic may still *)
(* carry one: it moved on unresolved, and its next owner resolves it.     *)
NoFinishWithConflict == ownerState \in {"delivered", "discarded"} => ~conflict
FinishLeavesMain ==
    ownerState \in {"delivered", "discarded"} => workspaceBase \in {"main", "dropped"}
(* A workspace is freed only by its released owner, with nothing in flight. *)
NoDropWhilePending ==
    workspaceBase = "dropped" => ~owner /\ (delivered \/ ~published)

(* Not rocket science: main only ever holds a topic commit a gate passed.  *)
MainOnlyHoldsPassedHeads == mainHead \in Heads => mainHead = passedHead
(* Delivery is the published commit itself, not a forge-made copy of it,  *)
(* so change IDs, trailers, and ancestry checks survive landing.           *)
DeliveryIsPublishedHead == delivered => mainHead = publishedHead
(* An edit or rebase after landing keeps the topic undelivered. *)
DeliveredHeadIsLocal == delivered => mainHead = head
(* A stacked topic lands only after its parent. *)
LandsAfterParent == delivered => parentLanded
(* Landing fast-forwards from the trunk the topic was based on: main moved *)
(* from the topic's own base, never from a trunk the gate did not test.   *)
LandingIsFastForward == delivered => landedOnto = base

(* The record and the session agree: active exactly while a task owns it. *)
OwnerRecordMatchesSession == (ownerState = "active") = active /\ (active => owner)
(* A claim directory exists exactly while a task is active; a claim left   *)
(* behind would refuse every later session.                               *)
ClaimOnlyWhileActive == claim = active
(* No task holds the canonical checkout of a repository with topic         *)
(* workspaces.                                                            *)
NoClaimOnSharedDefault == active => ~(workspaceKind = "default" /\ dedicated)
(* A record says delivered only when the topic landed; a release never     *)
(* passes for delivery.                                                   *)
DeliveredRecordIsTrue == ownerState = "delivered" => delivered
(* Unclaiming never rewrites, drops, or rebases the workspace it frees. *)
UnclaimKeepsWorkspace == ownerState = "released" => workspaceBase = "topic"
(* Unclaiming frees only a workspace whose owner's change is not checked out. *)
UnclaimOnlyOrphans == ownerState = "released" => ~checkedOut

===============================================================
