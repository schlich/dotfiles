---------------------- MODULE JjCi ----------------------
EXTENDS Naturals, FiniteSets, TLC

(***************************************************************************)
(* A bounded protocol model for the lifecycle enforced by jj/ci.nu.         *)
(*                                                                       *)
(* The model abstracts command execution and remote failures. It tracks   *)
(* only the safety-relevant facts: workspace ownership, topic readiness,  *)
(* exact published head, conflict state, and verified delivery.           *)
(***************************************************************************)

CONSTANTS Heads, MainHeads
ASSUME Heads # {} /\ MainHeads # {}

VARIABLES owner, active, head, base, conflict, validated,
          published, publishedHead, publishedValidated,
          publishedConflictFree, autoMergeHead, mergedHead,
          delivered, workspaceBase

vars == <<owner, active, head, base, conflict, validated,
          published, publishedHead, publishedValidated,
          publishedConflictFree, autoMergeHead, mergedHead,
          delivered, workspaceBase>>

Init ==
    /\ owner = TRUE
    /\ active = TRUE
    /\ head \in Heads
    /\ base \in MainHeads
    /\ conflict = FALSE
    /\ validated = FALSE
    /\ published = FALSE
    /\ publishedHead = "none"
    /\ publishedValidated = FALSE
    /\ publishedConflictFree = FALSE
    /\ autoMergeHead = "none"
    /\ mergedHead = "none"
    /\ delivered = FALSE
    /\ workspaceBase = "topic"

Edit ==
    /\ owner /\ active /\ ~delivered
    /\ \E h \in Heads :
         /\ head' = h
    /\ validated' = FALSE
    /\ UNCHANGED <<owner, active, base, conflict, published,
                   publishedHead, publishedValidated,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase>>

RebaseClean ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ \E b \in MainHeads :
         /\ base' = b
    /\ validated' = FALSE
    /\ UNCHANGED <<owner, active, head, conflict, published,
                   publishedHead, publishedValidated,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase>>

RebaseConflicted ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ conflict' = TRUE
    /\ validated' = FALSE
    /\ UNCHANGED <<owner, active, head, base, published, publishedHead,
                   publishedValidated, publishedConflictFree,
                   autoMergeHead, mergedHead, delivered, workspaceBase>>

Resolve ==
    /\ owner /\ active /\ conflict /\ ~delivered
    /\ conflict' = FALSE
    /\ validated' = FALSE
    /\ UNCHANGED <<owner, active, head, base, published, publishedHead,
                   publishedValidated, publishedConflictFree,
                   autoMergeHead, mergedHead, delivered, workspaceBase>>

Validate ==
    /\ owner /\ active /\ ~conflict /\ ~delivered
    /\ validated' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, published,
                   publishedHead, publishedValidated,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   delivered, workspaceBase>>

Publish ==
    /\ owner /\ active /\ validated /\ ~conflict /\ ~delivered
    /\ published' = TRUE
    /\ publishedHead' = head
    /\ publishedValidated' = validated
    /\ publishedConflictFree' = ~conflict
    /\ autoMergeHead' = "none"
    /\ UNCHANGED <<owner, active, head, base, conflict, validated,
                   mergedHead, delivered, workspaceBase>>

RequestAutoMerge ==
    /\ owner /\ active /\ published /\ ~conflict /\ ~delivered
    /\ publishedHead = head
    /\ autoMergeHead' = head
    /\ UNCHANGED <<owner, active, head, base, conflict, validated,
                   published, publishedHead, publishedValidated,
                   publishedConflictFree, mergedHead, delivered,
                   workspaceBase>>

Merge ==
    /\ published /\ ~conflict
    /\ publishedHead = head
    /\ (autoMergeHead = head \/ autoMergeHead = "none")
    /\ mergedHead' = head
    /\ UNCHANGED <<owner, active, head, base, conflict, validated,
                   published, publishedHead, publishedValidated,
                   publishedConflictFree, autoMergeHead, delivered,
                   workspaceBase>>

DeliverToMain ==
    /\ mergedHead = head
    /\ mergedHead = publishedHead
    /\ delivered' = TRUE
    /\ UNCHANGED <<owner, active, head, base, conflict, validated,
                   published, publishedHead, publishedValidated,
                   publishedConflictFree, autoMergeHead, mergedHead,
                   workspaceBase>>

Finish ==
    /\ owner /\ active /\ ~conflict
    /\ (delivered \/ ~published)
    /\ owner' = FALSE
    /\ active' = FALSE
    /\ workspaceBase' = "main"
    /\ UNCHANGED <<head, base, conflict, validated, published,
                   publishedHead, publishedValidated,
                   publishedConflictFree, autoMergeHead, mergedHead, delivered>>

Next == Edit \/ RebaseClean \/ RebaseConflicted \/ Resolve \/ Validate
        \/ Publish \/ RequestAutoMerge \/ Merge \/ DeliverToMain \/ Finish

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ owner \in BOOLEAN
    /\ active \in BOOLEAN
    /\ head \in Heads
    /\ base \in MainHeads
    /\ conflict \in BOOLEAN
    /\ validated \in BOOLEAN
    /\ published \in BOOLEAN
    /\ publishedHead \in Heads \cup {"none"}
    /\ publishedValidated \in BOOLEAN
    /\ publishedConflictFree \in BOOLEAN
    /\ autoMergeHead \in Heads \cup {"none"}
    /\ mergedHead \in Heads \cup {"none"}
    /\ delivered \in BOOLEAN
    /\ workspaceBase \in {"topic", "main"}

NoPublishWhileUnsafe ==
    published => publishedHead \in Heads /\ publishedValidated /\ publishedConflictFree
NoFinishWithConflict == ~(~owner /\ conflict)
FinishLeavesMain == ~active => workspaceBase = "main"
AutoMergePinsPublishedHead == autoMergeHead # "none" => autoMergeHead = publishedHead
DeliveryIsPublishedHead == delivered => mergedHead = publishedHead

===============================================================
