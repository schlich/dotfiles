# One view of a JJ workspace's topic for the prompt, the shell, and agents.
#
#   context-status            full readout
#   context-status prompt     one line for the Starship prompt
#   context-status brief      a few lines, printed when a shell enters a workspace
#   context-status handoff    Markdown for the next agent; --hook wraps it as
#                             Claude Code or Codex SessionStart hook output
#   context-status json       the collected record
#   context-status refresh    update the cached pipeline state now
#
# Local facts are read on every call: the change graph against trunk, the task
# owner, and jj-ci's publication and validation records. Pipeline and pull
# request state comes from `jj-ci ci-state`, cached in .jj/context-status.json
# and refreshed in the background, so the prompt never waits on the network.

const TRUNK = 'coalesce(remote_bookmarks(exact:"main", exact:"tangled"), trunk())'
const TRUNK_REMOTE = "tangled"
const CACHE_FILE = "context-status.json"
const LOCK_FILE = "context-status.lock"
# A pipeline still running is rechecked often; a settled verdict rarely.
const PENDING_TTL = 1min
const SETTLED_TTL = 15min
const LOCK_TTL = 2min

# Each revision as one JSON line. Trunk commits the topic lacks only count.
const REVISION_TEMPLATE = '
if(self.contained_in("::@"),
  "{\"above\":true"
    ++ ",\"wc\":" ++ json(self.current_working_copy())
    ++ ",\"change_id\":" ++ "\"" ++ change_id ++ "\""
    ++ ",\"short\":" ++ json(change_id.short(8))
    ++ ",\"commit_id\":" ++ "\"" ++ commit_id ++ "\""
    ++ ",\"empty\":" ++ json(empty)
    ++ ",\"conflict\":" ++ json(conflict)
    ++ ",\"described\":" ++ json(description != "")
    ++ ",\"title\":" ++ json(description.first_line())
    ++ ",\"impact\":" ++ json(trailers.filter(|t| t.key() == "Impact").map(|t| t.value()))
    ++ ",\"files\":[" ++ self.diff().files().map(|f| "[" ++ json(f.status()) ++ "," ++ json(f.path().display()) ++ "]").join(",") ++ "]"
    ++ "}\n",
  "{\"above\":false}\n")
'

# The state a Codex ownership record declares: none, active, delivered,
# discarded, or released. A record from before `state` has only `finished`,
# which proves release but never delivery. Keep in step with owner-status in
# jj/ci.nu.
def owner-status [owner: any] {
    if $owner == null { return "none" }
    let state = ($owner.state? | default "")
    if $state in ["active" "delivered" "discarded" "released"] { return $state }
    if ($owner.finished? | default false) { "released" } else { "active" }
}

# The nearest directory at or above `dir` that holds a JJ workspace.
def workspace-root [dir: path] {
    mut current = ($dir | path expand)
    loop {
        if ($current | path join ".jj" | path type) == "dir" { return $current }
        let parent = ($current | path dirname)
        if $parent == $current { return null }
        $current = $parent
    }
}

def require-root [dir?: path] {
    let root = (workspace-root ($dir | default $env.PWD))
    if $root == null { error make { msg: "Not inside a JJ workspace." } }
    $root
}

def read-json [path: path] {
    if not ($path | path exists) { return null }
    try { open --raw $path | from json } catch { null }
}

# Run from the root: JJ prints paths relative to the working directory.
def jj-lines [root: path, args: list<string>] {
    let result = (do { cd $root; ^jj ...$args | complete })
    if $result.exit_code != 0 { error make { msg: ($result.stderr | str trim) } }
    $result.stdout | lines | where {|line| $line | is-not-empty }
}

def remote-head [root: path, branch: string] {
    let revset = $"remote_bookmarks\(exact:'($branch)', exact:'($TRUNK_REMOTE)')"
    let result = (^jj --repository $root log --no-graph -r $revset -T 'commit_id' | complete)
    let commit = ($result.stdout | str trim)
    if $result.exit_code != 0 or ($commit | is-empty) { null } else { $commit }
}

def ago [when: any] {
    if $when == null { return "never" }
    let elapsed = ((date now) - ($when | into datetime))
    if $elapsed < 1min { "just now" } else if $elapsed < 1hr {
        $"($elapsed // 1min)min ago"
    } else if $elapsed < 1day {
        $"($elapsed // 1hr)h ago"
    } else {
        $"($elapsed // 1day)d ago"
    }
}

def ttl [ci: record] {
    if ($ci.spindle?.state? | default "") in ["success" "failed" "timeout"] { $SETTLED_TTL } else { $PENDING_TTL }
}

# Where the topic stands in the jj-ci lifecycle (see JjCi.tla): edited,
# validated at its head, published, passed by the pipeline, landed.
def lifecycle [facts: record] {
    if $facts.owner in ["delivered" "discarded"] { return "finished" }
    if $facts.stranded != null { return "stranded" }
    if $facts.ci?.landed? == true { return "landed" }
    if ($facts.stack | is-empty) { return "idle" }
    if $facts.published_head != null {
        if $facts.published_head != $facts.head.commit_id { return "republish" }
        return (match ($facts.ci?.spindle?.state? | default "unchecked") {
            "success" => "passed"
            "failed" => "failed"
            _ => "published"
        })
    }
    if $facts.lint == "passed" { "validated" } else { "editing" }
}

def next-step [facts: record] {
    if ($facts.conflicts | is-not-empty) {
        return "resolve the conflicts oldest first (`jj-ci conflicts` lists them), then `jj-ci validate`"
    }
    match $facts.stage {
        "stranded" => $"the working copy left this workspace's topic ($facts.stranded.short) \"($facts.stranded.title)\"; return with `jj edit ($facts.stranded.short)` and `jj abandon ($facts.stranded.stray)`"
        "finished" => "archive this task; start a new task for further work"
        "landed" => "run `jj-ci finish` to verify delivery and release the workspace"
        "idle" => "edit files to start the topic, or `jj-ci finish` if it was delivered"
        "editing" => (if not $facts.head.described {
            "describe the change with an `Impact:` trailer, then `jj-ci validate`"
        } else { "run `jj-ci validate`, then `jj-ci publish`" })
        "validated" => "run `jj-ci publish`"
        "republish" => "the head moved since publication; run `jj-ci publish` to update the branch"
        "published" => (if $facts.ci?.spindle?.state? == "timeout" {
            "the spindle timed out, which does not gate landing; `jj-ci land` builds the checks locally when the topic is ready"
        } else { "wait for the pipeline, or `jj-ci land` once the topic is ready" })
        "passed" => "run `jj-ci land` when the topic is ready to deliver"
        "failed" => "inspect the failed pipeline, fix the topic, and `jj-ci publish` again"
        _ => ""
    }
}

# Whether the working copy has wandered off the topic that `jj-ci start`
# recorded. Keep in step with topic-stranded in jj/ci.nu, which refuses jj-ci
# commands in this state.
def topic-stranded [facts: record] {
    $facts.recorded and $facts.visible and not $facts.landed and not $facts.ancestor and $facts.working_copy_empty and not $facts.topic_empty
}

# The recorded topic this workspace has left, as { short title stray } with
# stray the working copy that left it, or null. A topic in the stack below the
# working copy needs no JJ call to rule out.
def stranded-topic [root: path, stack_ids: list, wc: record] {
    let marker = (read-json ($root | path join ".jj" "jj-ci-workspace.json"))
    let topic = ($marker.change_id? | default null)
    if $topic == null or $topic in $stack_ids or not $wc.empty { return null }
    # The trunk revset sits inside a template string, so its quotes are escaped.
    let trunk = ($TRUNK | str replace --all '"' '\"')
    let template = ('"{\"landed\":" ++ json(self.contained_in("::' + $trunk + '")) ++ ",\"ancestor\":" ++ json(self.contained_in("::@")) ++ ",\"empty\":" ++ json(empty && description == "") ++ ",\"short\":" ++ json(change_id.short(8)) ++ ",\"title\":" ++ json(description.first_line()) ++ "}\n"')
    let found = (try { jj-lines $root [log --no-graph -r $"change_id\(($topic))" -T $template] } catch { [] })
    let topic_facts = ($found | get --optional 0 | if $in == null { null } else { $in | from json })
    let stranded = (topic-stranded {
        recorded: true
        visible: ($topic_facts != null)
        landed: ($topic_facts.landed? | default false)
        ancestor: ($topic_facts.ancestor? | default false)
        working_copy_empty: $wc.empty
        topic_empty: ($topic_facts.empty? | default false)
    })
    if $stranded { $topic_facts | select short title | insert stray $wc.short } else { null }
}

# Every local fact, plus the cached pipeline state for the published head.
def collect [root: path] {
    let revset = ('@ | (' + $TRUNK + '..@) | (@..' + $TRUNK + ')')
    let revisions = (jj-lines $root [log --no-graph -r $revset -T $REVISION_TEMPLATE] | each {|line| $line | from json }
        | each {|rev| if $rev.above and ($rev.title | is-empty) { $rev | update title "(no description)" } else { $rev } })
    let above = ($revisions | where above)
    let wc = ($above | where wc | first)
    # An empty, undescribed working copy is scratch space; the topic is below.
    let scratch = ($wc.empty and not $wc.described)
    let stack = ($above | where {|rev| not ($rev.wc and $scratch) } | reverse)
    let head = if ($stack | is-empty) { $wc } else { $stack | last }

    let jj_dir = ($root | path join ".jj")
    # A task owns the change it recorded; a record naming another change is
    # left over from an earlier task in this workspace.
    let owner_record = (read-json ($jj_dir | path join "codex-session.json"))
    let owned = $owner_record != null and ($owner_record.change_id? in [$wc.change_id $head.change_id])
    let owner = if $owned { owner-status $owner_record } else { "none" }
    let topics = ((read-json ($jj_dir | path join "jj-ci-publication.json")) | default {} | get --optional topics | default {})
    let branch = ($topics | get --optional $head.change_id)
    let published_head = if $branch == null { null } else { remote-head $root $branch }
    let validation = (read-json ($jj_dir | path join "jj-ci-validation.json"))
    let lint = if $validation == null { "never" } else if $validation.commit_id == $head.commit_id { "passed" } else { "stale" }
    let cache = (read-json ($jj_dir | path join $CACHE_FILE))
    let ci = if $cache != null and $published_head != null and $cache.state?.published_head? == $published_head { $cache.state } else { null }
    let stranded = (stranded-topic $root ($stack | get change_id) $wc)

    let facts = {
        root: $root
        workspace: ($root | path basename)
        owner: $owner
        owner_change: (if $owned { $owner_record.change_id } else { null })
        checked_out: ([$wc.change_id $head.change_id] | uniq)
        head: $head
        stack: $stack
        behind: ($revisions | where not above | length)
        conflicts: ($stack | where conflict | get short)
        working_copy: (if $scratch { [] } else { $wc.files })
        branch: $branch
        published_head: $published_head
        lint: $lint
        validated_at: ($validation.validated_at? | default null)
        ci: $ci
        ci_checked_at: (if $ci == null { null } else { $cache.checked_at })
        refresh_due: ($published_head != null and ($ci == null or ((date now) - ($cache.checked_at | into datetime)) > (ttl $ci)))
        stranded: $stranded
    }
    let facts = ($facts | insert stage (lifecycle $facts))
    $facts | insert next (next-step $facts)
}

def locked [root: path] {
    let lock = ($root | path join ".jj" $LOCK_FILE)
    ($lock | path exists) and ((date now) - (ls --long $lock | first | get modified)) < $LOCK_TTL
}

def refresh-now [root: path] {
    let lock = ($root | path join ".jj" $LOCK_FILE)
    touch $lock
    let result = (do { cd $root; ^jj-ci ci-state } | complete)
    if $result.exit_code == 0 {
        let state = (try { $result.stdout | from json } catch { null })
        if $state != null {
            { checked_at: (date now | format date "%+") state: $state } | to json | save --force ($root | path join ".jj" $CACHE_FILE)
        }
    }
    rm --force $lock
}

# Refresh the pipeline cache in a detached process so the caller returns now.
def refresh-in-background [facts: record] {
    if not $facts.refresh_due or (locked $facts.root) { return }
    touch ($facts.root | path join ".jj" $LOCK_FILE)
    try {
        ^setsid --fork $nu.current-exe --no-config-file $env.CURRENT_FILE refresh $facts.root o+e> /dev/null
    } catch { }
}

def ci-glyph [state: any] {
    match $state {
        "success" => $"(ansi green)✔(ansi reset)"
        "failed" => $"(ansi red)✗(ansi reset)"
        "timeout" => $"(ansi dark_gray)⌛(ansi reset)"
        "running" | "in_progress" | "queued" => $"(ansi yellow)⧗(ansi reset)"
        "missing" => $"(ansi yellow)…(ansi reset)"
        _ => $"(ansi dark_gray)?(ansi reset)"
    }
}

def stage-label [stage: string] {
    match $stage {
        "editing" => $"(ansi blue)✎ editing(ansi reset)"
        "validated" => $"(ansi cyan)✓ validated(ansi reset)"
        "republish" => $"(ansi yellow)↻ edited since publish(ansi reset)"
        "stranded" => $"(ansi red)⚠ off topic(ansi reset)"
        "published" => $"(ansi purple)↑ published(ansi reset)"
        "passed" => $"(ansi green)✔ passed(ansi reset)"
        "failed" => $"(ansi red)✗ pipeline failed(ansi reset)"
        "landed" => $"(ansi green)⚑ landed(ansi reset)"
        "finished" => $"(ansi dark_gray)⚑ finished(ansi reset)"
        _ => $"(ansi dark_gray)· idle(ansi reset)"
    }
}

def ci-summary [facts: record] {
    if $facts.published_head == null { return "not published" }
    if $facts.ci == null { return $"published ($facts.published_head | str substring 0..7), pipeline not checked yet" }
    let parts = [
        (match ($facts.ci.spindle?.state? | default "unknown") {
            "timeout" => "spindle timed out (not the landing gate)"
            $state => $"spindle ($state)"
        })
        (if $facts.ci.github? != null { $"GitHub ($facts.ci.github.state)" })
        (if $facts.ci.pull? != null { $"PR \"($facts.ci.pull)\"" })
    ] | compact
    $"($parts | str join ', ') on ($facts.published_head | str substring 0..7) \(checked (ago $facts.ci_checked_at))"
}

def lint-summary [facts: record] {
    match $facts.lint {
        "passed" => $"Prek passed on this head \((ago $facts.validated_at))"
        "stale" => "not validated since the last edit"
        _ => "never validated in this workspace"
    }
}

def topic-title [facts: record] {
    let title = if $facts.head.described { $"\"($facts.head.title)\"" } else { "(no description)" }
    let impact = ($facts.stack | each {|rev| $rev.impact } | flatten | uniq)
    let impact_label = if ($impact | is-empty) { "no Impact trailer" } else { $impact | str join "+" }
    $"($facts.head.short) ($title) · ($impact_label)"
}

def "main prompt" [] {
    let root = (workspace-root $env.PWD)
    if $root == null { return }
    let facts = (try { collect $root } catch { return })
    refresh-in-background $facts
    let parts = [
        (if ($facts.conflicts | is-not-empty) { $"(ansi red)⚠ conflict(ansi reset)" })
        (if $facts.stage != "idle" { stage-label $facts.stage })
        (if $facts.stage in ["published" "passed" "failed" "republish"] and $facts.ci != null { ci-glyph $facts.ci.spindle?.state? })
        (if $facts.behind > 0 and $facts.stage != "idle" { $"(ansi dark_gray)↓($facts.behind)(ansi reset)" })
        (if $facts.owner == "active" { $"(ansi dark_gray)◆(ansi reset)" })
    ] | compact
    print --no-newline ($parts | str join " ")
}

def "main brief" [dir?: path] {
    let facts = (collect (require-root $dir))
    refresh-in-background $facts
    print-brief $facts
}

def print-brief [facts: record] {
    let conflicts = if ($facts.conflicts | is-empty) { "no conflicts" } else { $"(ansi red)conflicts in ($facts.conflicts | str join ', ')(ansi reset)" }
    print $"(ansi attr_bold)($facts.workspace)(ansi reset)  (topic-title $facts)"
    print $"  (stage-label $facts.stage) · next: ($facts.next)"
    print $"  ($facts.stack | length) above trunk, ($facts.behind) behind · ($conflicts) · lint: (lint-summary $facts)"
    if $facts.published_head != null { print $"  ci: (ci-summary $facts)" }
}

def "main json" [dir?: path] {
    collect (require-root $dir) | to json
}

def "main refresh" [dir?: path] {
    refresh-now (require-root $dir)
}

def handoff-text [facts: record] {
    let owner = match $facts.owner {
        "active" => $"owned by an active Codex task on change ($facts.owner_change)"
        "delivered" => "its Codex task delivered the topic"
        "discarded" => "its Codex task ended without delivering"
        "released" => "its Codex task released the workspace; the topic may continue elsewhere"
        _ => "no task owner recorded"
    }
    let stack = ($facts.stack | each {|rev|
        let flags = ([(if $rev.conflict { "conflicted" }) (if not $rev.described { "undescribed" })] | compact)
        let suffix = if ($flags | is-empty) { "" } else { $" [($flags | str join ', ')]" }
        $"  - ($rev.short) ($rev.title)($suffix)"
    })
    let files = ($facts.working_copy | each {|file| $"($file.0) ($file.1)" })
    [
        $"JJ workspace context \(context-status, (date now | format date '%Y-%m-%d %H:%M %Z')):"
        $"- Workspace: ($facts.root), ($owner)."
        $"- Topic: (topic-title $facts | ansi strip)."
        $"- Stage: ($facts.stage). Next: ($facts.next)."
        (if ($stack | is-not-empty) { (["- Changes above trunk, oldest first:"] | append $stack | str join "\n") })
        $"- Trunk: ($facts.behind) trunk commits are not in this topic. Conflicts: (if ($facts.conflicts | is-empty) { 'none' } else { $facts.conflicts | str join ', ' })."
        (if ($files | is-not-empty) { $"- Working copy: ($files | length) files changed: ($files | str join ', ')." })
        $"- Lint: (lint-summary $facts)."
        $"- CI: (ci-summary $facts)."
    ] | compact | str join "\n"
}

# Markdown for the next agent. As a SessionStart hook it reads the hook event
# from stdin and never waits on the network; run directly it refreshes a stale
# pipeline verdict first.
def "main handoff" [
    dir?: path
    --hook # Read a Claude Code or Codex hook event on stdin and answer with additionalContext
] {
    if $hook {
        let event = (try { open --raw /dev/stdin | from json } catch { {} })
        let root = (workspace-root ($event.cwd? | default $env.PWD))
        if $root == null { return }
        let facts = (try { collect $root } catch { return })
        refresh-in-background $facts
        { hookSpecificOutput: {
            hookEventName: ($event.hook_event_name? | default "SessionStart")
            additionalContext: (handoff-text $facts)
        } } | to json --raw | print
        return
    }
    let root = (require-root $dir)
    let facts = (collect $root)
    let facts = if $facts.refresh_due and not (locked $root) { refresh-now $root; collect $root } else { $facts }
    print (handoff-text $facts)
}

# Audit: every workspace of the repository checked against the ownership and
# publication invariants in jj/JjCi.tla. It reads state and reports; each
# finding names the command that repairs it.

const SEVERITIES = ["error" "warning" "info"]

# Findings for one workspace, from facts `audit-facts` gathers:
#   name, root, exists, error      the workspace and whether it could be read
#   default, dedicated             canonical checkout of a repository with
#                                  topic workspaces
#   owner, owner_change, legacy    the ownership record's status, change, and
#                                  whether it predates `state`
#   owner_checked_out              whether that change is checked out here
#   claim                          whether a claim directory exists
#   stack, published, behind       work above trunk, whether it has a branch
#   conflicts                      conflicted revisions in the stack
#   stale_entries                  publication entries for changes not here
#   stranded                       the working copy left its `jj-ci start` topic
def audit-findings [facts: record] {
    let finding = {|severity, code, detail, fix| { workspace: $facts.name severity: $severity code: $code detail: $detail fix: $fix } }
    if not $facts.exists {
        return [(do $finding "error" "missing-workspace" $"($facts.root) no longer exists." "`jj-ci prune --apply` forgets it")]
    }
    if $facts.error != null {
        return [(do $finding "error" "unreadable" $facts.error "`jj workspace update-stale` in the workspace, then audit again")]
    }
    let change = ($facts.owner_change | default "" | str substring 0..7)
    [
        # TLA: OwnerRecordMatchesSession, UnclaimOnlyOrphans.
        (if $facts.owner == "active" and not $facts.owner_checked_out {
            do $finding "error" "orphaned-claim" $"An active task owns change ($change), which is no longer checked out here; every new session is refused." "`jj-ci unclaim` in the workspace"
        })
        # The topic guard in jj/ci.nu: jj-ci refuses to run until the working
        # copy returns (TLA: topic commands require `checkedOut`).
        (if $facts.stranded {
            do $finding "error" "stranded-topic" "The working copy left the topic `jj-ci start` recorded; jj-ci refuses to run here." "`jj edit` the topic, as `context-status` in the workspace names it"
        })
        # TLA: ClaimOnlyWhileActive.
        (if $facts.claim and $facts.owner != "active" {
            do $finding "error" "leftover-claim" "A session claim remains without an active task; new Codex sessions are refused." "`jj-ci unclaim` in the workspace"
        })
        # TLA: NoClaimOnSharedDefault.
        (if $facts.owner == "active" and $facts.default and $facts.dedicated {
            do $finding "error" "shared-default-claim" $"A task owns the canonical checkout with change ($change)." "move the topic to `jj-ci start NAME`, then `jj-ci unclaim` here"
        })
        # TLA: DeliveredRecordIsTrue.
        (if $facts.legacy {
            do $finding "warning" "legacy-record" $"The ownership record for change ($change) predates `state`; it cannot say whether the topic was delivered." "check the topic's branch; `jj-ci finish` or `jj-ci unclaim` rewrites the record"
        })
        (if ($facts.conflicts | is-not-empty) {
            do $finding "warning" "conflicts" $"Conflicted revisions: ($facts.conflicts | str join ', ')." "resolve oldest first; `jj-ci conflicts` lists them"
        })
        (if $facts.stack > 0 and not $facts.published {
            let behind = if $facts.behind > 0 { $", based ($facts.behind) trunk commits back" } else { "" }
            do $finding "warning" "unpublished-work" $"The head of ($facts.stack) change\(s) above trunk is unpublished($behind); `jj-ci status` does not list it." "`jj-ci publish` it, or `jj-ci abandon` it"
        })
        (if ($facts.stale_entries | is-not-empty) {
            do $finding "info" "stale-publication-entries" $"($facts.stale_entries | length) publication entries name changes not checked out here: ($facts.stale_entries | str join ', ')." "harmless; they are reused only if those changes return here"
        })
    ] | compact
}

def list-workspaces [root: path] {
    jj-lines $root [workspace list -T 'name ++ "\t" ++ root ++ "\n"'] | parse "{name}\t{root}"
}

def audit-facts [workspace: record, dedicated: bool] {
    let blank = {
        name: $workspace.name root: $workspace.root exists: false error: null
        default: ($workspace.name == "default") dedicated: $dedicated
        owner: "none" owner_change: null legacy: false owner_checked_out: false claim: false
        stack: 0 published: false behind: 0 conflicts: [] stale_entries: [] stranded: false
    }
    if not ($workspace.root | path exists) { return $blank }
    let jj_dir = ($workspace.root | path join ".jj")
    let record = (read-json ($jj_dir | path join "codex-session.json"))
    let facts = (try { collect $workspace.root } catch {|err| return ($blank | merge { exists: true error: ($err.msg | lines | first) }) })
    let topics = ((read-json ($jj_dir | path join "jj-ci-publication.json")) | default {} | get --optional topics | default {})
    $blank | merge {
        exists: true
        owner: (owner-status $record)
        owner_change: ($record.change_id? | default null)
        legacy: ($record != null and ($record.state? | default "") == "" and ($record.finished? | default false))
        owner_checked_out: ($record != null and ($record.change_id? in $facts.checked_out))
        claim: ($jj_dir | path join "codex-session-claim" | path exists)
        stack: ($facts.stack | length)
        published: ($facts.branch != null)
        behind: $facts.behind
        conflicts: $facts.conflicts
        stale_entries: ($topics | transpose change branch | where {|entry| $entry.change not-in $facts.checked_out } | get branch)
        stranded: ($facts.stranded != null)
    }
}

# Codex session records whose workspace no longer exists.
def orphaned-session-records [] {
    let dir = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state") | path join "codex-jj-sessions")
    if not ($dir | path exists) { return [] }
    ls $dir | get name | each {|path| read-json $path } | compact | where {|state| not ($state.cwd? | default "" | path exists) }
}

def "main audit" [
    dir?: path
    --json # Print the findings as JSON
] {
    let root = (require-root $dir)
    let workspaces = (list-workspaces $root)
    let dedicated = (($workspaces | length) > 1)
    let findings = ($workspaces | each {|workspace| audit-findings (audit-facts $workspace $dedicated) } | flatten)
    let orphans = (orphaned-session-records)
    let findings = if ($orphans | is-empty) { $findings } else {
        $findings | append { workspace: "(codex)" severity: "info" code: "orphaned-session-records" detail: $"($orphans | length) Codex session records name workspaces that no longer exist." fix: "harmless; delete them from $XDG_STATE_HOME/codex-jj-sessions" }
    }
    if $json { return ($findings | to json) }
    if ($findings | is-empty) {
        print $"(ansi green)✔(ansi reset) ($workspaces | length) workspaces, no findings."
        return
    }
    for group in ($findings | group-by workspace | transpose workspace items) {
        print $"(ansi attr_bold)($group.workspace)(ansi reset)"
        for item in $group.items {
            let color = match $item.severity { "error" => (ansi red) "warning" => (ansi yellow) _ => (ansi dark_gray) }
            print $"  ($color)($item.severity)(ansi reset) ($item.code): ($item.detail)"
            print $"    fix: ($item.fix)"
        }
    }
    let counts = ($SEVERITIES | each {|severity| $"($findings | where severity == $severity | length) ($severity)" } | str join ", ")
    print $"\n($workspaces | length) workspaces: ($counts)."
}

def main [dir?: path] {
    let root = (require-root $dir)
    let facts = (collect $root)
    let facts = if $facts.refresh_due and not (locked $root) { refresh-now $root; collect $root } else { $facts }
    print-brief $facts
    if ($facts.stack | is-not-empty) {
        print ""
        for rev in $facts.stack {
            let conflict = if $rev.conflict { $" (ansi red)conflict(ansi reset)" } else { "" }
            let impact = if ($rev.impact | is-empty) { "" } else { $" (ansi dark_gray)($rev.impact | str join '+')(ansi reset)" }
            print $"  ($rev.short) ($rev.title)($impact)($conflict)"
        }
    }
    if ($facts.working_copy | is-not-empty) {
        print ""
        for file in $facts.working_copy { print $"  ($file.0) ($file.1)" }
    }
    if $facts.published_head != null and $facts.ci == null { print "\n  (pipeline state unavailable; is jj-ci current?)" }
}
