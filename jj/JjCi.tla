---------------------- MODULE JjCi ----------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************)
(* A bounded protocol model for the lifecycle enforced by jj/ci.nu.         *)
(*                                                                       *)
(* The model abstracts command execution and remote failures. It tracks   *)
(* only the safety-relevant facts: workspace ownership, topic readiness,  *)
(* exact published head, conflict state, stacked-PR base, and verified    *)
(* delivery.                                                              *)
(* Validation is tagged with the head it checked and the head captured at *)
(* publication, so later edits cannot blur that relationship.              *)
(***************************************************************************)

CONSTANTS Heads, MainHeads
ASSUME Heads # {} /\ MainHeads # {}

VARIABLES owner, active, head, base, conflict, validated, validatedHead,
          published, publishedHead, publishedValidated, publishedValidationHead,
          publishedConflictFree, autoMergeHead, mergedHead,
          delivered, workspaceBase, prBase, deferred

vars == <<owner, active, head, base, conflict, validated, validatedHead,
          published, publishedHead, publishedValidated, publishedValidationHead,
          publishedConflictFree, autoMergeHead, mergedHead,
          delivered, workspaceBase, prBase, deferred>>

(* prBase is "parent" while the topic is stacked on an open PR and "main"  *)
(* once that parent has landed and GitHub retargets it. deferred records  *)
(* the jj-ci:auto-merge label on a stacked PR.                            *)
stackVars == <<prBase, deferred>>

Init ==
    /\ owner = TRUE
    /\ active = TRUE
    /\ head \in Heads
    /\ base \in MainHeads
    /\ conflict = FALSE
    /\ validated = FALSE
    /\ validatedHead = "none"
    /\ published = FALSE
    /\ publishedHead = "none"
    /\ publishedValidated = FALSE
    /\ publishedValidationHead = "none"
    /\ publishedConflictFree = FALSE
    /\ autoMergeHead = "none"
    /\ mergedHead = "none"
    /\ delivered = FALSE
    /\ workspaceBase = "topic"
    /\ prBase \in {"main", "parent"}
    /\ deferred = FALSE

Edit ==
    /\ owner /\ active /\ ~delivered
    /\ \E h \in Heads :
         /\ head' = h
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, base, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase>>
    /\ UNCHANGED stackVars

(* A rebase rewrites every commit in the topic, so the head changes too. *)
RebaseClean ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ \E b \in MainHeads, h \in Heads :
         /\ base' = b
         /\ head' = h
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase>>
    /\ UNCHANGED stackVars

RebaseConflicted ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ \E h \in Heads :
         /\ head' = h
    /\ conflict' = TRUE
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, base, published, publishedHead,
                   publishedValidated, publishedValidationHead, publishedConflictFree,
                   autoMergeHead, mergedHead, delivered, workspaceBase>>
    /\ UNCHANGED stackVars

Resolve ==
    /\ owner /\ active /\ conflict /\ ~delivered
    /\ conflict' = FALSE
    /\ validated' = FALSE
    /\ validatedHead' = "none"
    /\ UNCHANGED <<owner, active, head, base, published, publishedHead,
                   publishedValidated, publishedValidationHead, publishedConflictFree,
                   autoMergeHead, mergedHead, delivered, workspaceBase>>
    /\ UNCHANGED stackVars

Validate ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ validated' = TRUE
    /\ validatedHead' = head
    /\ UNCHANGED <<owner, active, head, base, conflict, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase>>
    /\ UNCHANGED stackVars

(* Pushing a new head disarms auto-merge, which was pinned to the old one. *)
Publish ==
    /\ owner /\ active /\ validated /\ validatedHead = head
    /\ ~conflict /\ ~delivered
    /\ published' = TRUE
    /\ publishedHead' = head
    /\ publishedValidated' = validated
    /\ publishedValidationHead' = validatedHead
    /\ publishedConflictFree' = ~conflict
    /\ autoMergeHead' = "none"
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   mergedHead, delivered, workspaceBase>>
    /\ UNCHANGED stackVars

(* A stacked PR would merge into its parent's branch, so the request is    *)
(* recorded as a label instead of arming GitHub auto-merge. Arming a PR   *)
(* that targets main removes any leftover label.                          *)
RequestAutoMerge ==
    /\ owner /\ active /\ published /\ ~conflict /\ ~delivered
    /\ publishedHead = head
    /\ IF prBase = "main"
         THEN /\ autoMergeHead' = head
              /\ deferred' = FALSE
         ELSE /\ deferred' = TRUE
              /\ UNCHANGED autoMergeHead
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, mergedHead, delivered,
                   workspaceBase, prBase>>

(* The parent PR lands and GitHub retargets this PR to main. *)
ParentLands ==
    /\ prBase = "parent"
    /\ prBase' = "main"
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase, deferred>>

(* jj-ci refresh arms a deferred request once the PR targets main. *)
ArmDeferred ==
    /\ prBase = "main" /\ deferred
    /\ published /\ ~conflict
    /\ publishedHead = head
    /\ autoMergeHead' = head
    /\ deferred' = FALSE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, mergedHead, delivered,
                   workspaceBase, prBase>>

(* GitHub merges the published head, by auto-merge or manually. *)
Merge ==
    /\ published /\ ~conflict
    /\ prBase = "main"
    /\ publishedHead = head
    /\ (autoMergeHead = head \/ autoMergeHead = "none")
    /\ mergedHead' = head
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, delivered,
                   workspaceBase>>
    /\ UNCHANGED stackVars

DeliverToMain ==
    /\ mergedHead = head
    /\ mergedHead = publishedHead
    /\ delivered' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated, validatedHead,
                   published, publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   workspaceBase>>
    /\ UNCHANGED stackVars

(* Releasing a topic leaves its workspace on main (--keep, or one that    *)
(* jj-ci start did not create) or drops it, so no workspace outlives its  *)
(* owner.                                                                 *)
Finish ==
    /\ owner /\ active /\ ~conflict
    /\ (delivered \/ ~published)
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ workspaceBase' \in {"main", "dropped"}
    /\ UNCHANGED <<head, base, conflict, validated, validatedHead, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead, delivered>>
    /\ UNCHANGED stackVars

(* Abandoning discards unpublished work, conflicts included. The model    *)
(* omits PR closure, so a published topic cannot be abandoned.            *)
Abandon ==
    /\ owner /\ active /\ ~published
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ conflict' = FALSE
    /\ workspaceBase' \in {"main", "dropped"}
    /\ UNCHANGED <<head, base, validated, validatedHead, published,
                   publishedHead, publishedValidated, publishedValidationHead,
                   publishedConflictFree, autoMergeHead, mergedHead, delivered>>
    /\ UNCHANGED stackVars

Next == Edit \/ RebaseClean \/ RebaseConflicted \/ Resolve \/ Validate
        \/ Publish \/ RequestAutoMerge \/ ParentLands \/ ArmDeferred
        \/ Merge \/ DeliverToMain \/ Finish \/ Abandon

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
    /\ autoMergeHead \in Heads \cup {"none"}
    /\ mergedHead \in Heads \cup {"none"}
    /\ delivered \in BOOLEAN
    /\ workspaceBase \in {"topic", "main", "dropped"}
    /\ prBase \in {"main", "parent"}
    /\ deferred \in BOOLEAN

NoPublishWhileUnsafe ==
    published => publishedHead \in Heads /\ publishedValidated /\ publishedConflictFree
PublishedHeadWasValidated == published => publishedHead = publishedValidationHead
NoFinishWithConflict == ~(~owner /\ conflict)
FinishLeavesMain == ~active => workspaceBase \in {"main", "dropped"}
(* A workspace is freed only by its released owner, with nothing in flight. *)
NoDropWhilePending ==
    workspaceBase = "dropped" => ~owner /\ (delivered \/ ~published)
AutoMergePinsPublishedHead == autoMergeHead # "none" => autoMergeHead = publishedHead
DeliveryIsPublishedHead == delivered => mergedHead = publishedHead

(* GitHub auto-merge on a stacked PR would merge into the parent branch. *)
AutoMergeOnlyTargetsMain == autoMergeHead # "none" => prBase = "main"
DeferredOnlyWhileUnarmed == deferred => autoMergeHead = "none"
MergeOnlyIntoMain == mergedHead # "none" => prBase = "main"
(* An edit or rebase after merging keeps the topic undelivered. *)
DeliveredHeadIsLocal == delivered => mergedHead = head

===============================================================
