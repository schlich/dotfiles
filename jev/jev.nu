#!/usr/bin/env -S nu --stdin

# Command-line access to TypeSafe's Jev System One model.
# Questions and thresholds live in the file named by JEV_QUESTIONS.
# TYPESAFE_BASE_URL names another API root that serves /v1/systemone, as in
# TypeSafe's SDKs, such as a local open decision model.

const default_base_url = "https://api.typesafe.ai"
const systemone_path = "/v1/systemone"
# Command lines that assign credentials are never sent to the API. This
# matches Nushell's `$env.FOO_TOKEN = ...` as well as the `FOO_TOKEN=...`
# prefix and `export FOO_TOKEN=...` forms that Bash and Nushell commands use,
# and mirrors the filters in modules/tooling/ai/scripts/agent-trust.nu and
# prefer-nushell-bash.nu. A credential passed inline, such as a token
# argument, is not recognized.
const credential_pattern = '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

# Hook runners spawn jev with a socket for stdin, and Linux cannot reopen a
# socket through /dev/stdin, so read `$in`, which requires `nu --stdin`.
def parse-stdin [input: any] {
    if ($input | describe) == "nothing" {
        error make { msg: "no JSON on stdin; run jev with `nu --stdin`" }
    }
    # `from json` accepts bare words and empty input, so require an object.
    let value = ($input | into string | from json)
    if not ($value | describe | str starts-with "record") {
        error make { msg: $"stdin is not a JSON object \(got ($value | describe)\)" }
    }
    $value
}

def questions-config [] {
    let path = ($env.JEV_QUESTIONS? | default ($env.FILE_PWD | path join "questions.nuon"))
    open $path
}

# A key with an embedded line break makes the HTTP client fail with an
# opaque "Network failure", so reject it with a clear message instead.
def validated-key [key: string, source: string] {
    let parts = ($key | lines | each { str trim } | where { is-not-empty })
    if ($parts | length) != 1 {
        error make { msg: $"TYPESAFE_API_KEY from ($source) is malformed: expected one line, got ($parts | length) non-empty lines. Store it again as a single line." }
    }
    # Terminal paste shortcuts can leave control characters such as Ctrl-V.
    let invalid = ($parts.0 | split chars | enumerate | where { $in.item !~ '^[\x21-\x7e]$' } | get index)
    if ($invalid | is-not-empty) {
        error make { msg: $"TYPESAFE_API_KEY from ($source) contains non-printable characters at positions ($invalid | str join ', '). Store it again without control characters." }
    }
    $parts.0
}

# The API root with any trailing slash removed, or "" when TYPESAFE_BASE_URL
# is unset or empty.
def base-url-override [] {
    $env.TYPESAFE_BASE_URL? | default "" | str trim | str trim --right --char "/"
}

def endpoint [] {
    let base = (base-url-override)
    $"(if ($base | is-empty) { $default_base_url } else { $base })($systemone_path)"
}

# The TypeSafe key, or null when none should be sent. The key stored in the
# keyring goes only to TypeSafe: with TYPESAFE_BASE_URL set, a key is sent
# only when TYPESAFE_API_KEY is set, so pointing jev at another server never
# hands it the stored key.
def api-key [] {
    if ($env.TYPESAFE_API_KEY? | is-not-empty) {
        return (validated-key $env.TYPESAFE_API_KEY "the environment")
    }
    if (base-url-override | is-not-empty) {
        return null
    }
    let manifest = ($env.JEV_SECRETSPEC_FILE? | default ($env.FILE_PWD | path join ".." "modules" "secretspec.toml"))
    let result = (^secretspec get --file $manifest --provider keyring --profile default --reason "Jev decision request" TYPESAFE_API_KEY | complete)
    if $result.exit_code != 0 or ($result.stdout | str trim | is-empty) {
        error make { msg: "TYPESAFE_API_KEY is not set and is not available from secretspec." }
    }
    validated-key $result.stdout "secretspec"
}

def usage-log [] {
    let state = ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state"))
    $env.JEV_USAGE_LOG? | default ($state | path join "jev" "usage.jsonl")
}

# TypeSafe reports token usage per response and has no account usage API,
# so append each response to a ledger that dashboards such as Fieldnotes sum.
# A ledger that cannot be written never fails the request.
def record-usage [command: string, model: string, response: record] {
    let body = $response.body
    let usage = if ($body | describe | str starts-with "record") { $body.usage? | default {} } else { {} }
    try {
        let path = (usage-log)
        mkdir ($path | path dirname)
        let entry = {
            at: (date now | format date "%Y-%m-%dT%H:%M:%S%:z")
            command: $command
            model: $model
            # Lets a dashboard tell TypeSafe's billed usage from a local server's.
            endpoint: (endpoint)
            status: $response.status
            input_tokens: ($usage.input_tokens? | default 0)
            output_tokens: ($usage.output_tokens? | default 0)
        }
        $"($entry | to json -r)\n" | save --append $path
    }
}

# Evaluate `state` against typed questions and return the full response.
# `command` names the caller in the usage ledger.
def ask [state: any, questions: record, model: string, command: string] {
    let key = (api-key)
    let headers = if $key == null { {} } else { { Authorization: $"Bearer ($key)" } }
    let response = (
        http post (endpoint) { state: $state, model: $model, questions: $questions }
            --content-type application/json
            --headers $headers
            --max-time 15sec
            --full
            --allow-errors
    )
    record-usage $command $model $response
    if $response.status != 200 {
        error make { msg: $"Jev request failed with HTTP ($response.status): ($response.body | to json -r)" }
    }
    $response.body
}

# Ask ad hoc questions. Reads `{state, questions}` JSON from stdin and prints
# the response JSON.
def "main ask" [
    --model: string # Model ID; defaults to the pinned model in the questions file
] {
    let request = (parse-stdin $in)
    let model = ($model | default (questions-config).model)
    ask $request.state $request.questions $model "ask" | to json
}

# Label a task's difficulty and error cost for quota-advisor. Reads `{task}`
# JSON from stdin and prints the response JSON. A task that assigns a
# credential is never sent, and every failure exits nonzero so the advisor
# falls back to its offline policy.
def "main classify-task" [] {
    let task = ((parse-stdin $in).task? | default "")
    if ($task | str trim | is-empty) {
        error make { msg: "no task description on stdin" }
    }
    if $task =~ $credential_pattern {
        error make { msg: "the task assigns a credential, so it is not sent to Jev" }
    }
    let config = (questions-config)
    ask { task: $task } $config.classify_task.questions $config.model "classify-task" | to json
}

# Decide whether a failed terminal command deserves an agent. Reads a
# `terminal.command.failed` event as JSON on stdin and prints a routing record.
# Any failure to reach Jev routes to triage, preserving the previous behavior.
def "main triage-gate" [] {
    let event = (parse-stdin $in)
    let command = ($event.command? | default "")
    let exit_code = ($event.exit_code? | default null)

    if $command =~ $credential_pattern {
        return ({ route: "triage", reason: "credential assignment is not sent to Jev" } | to json -r)
    }

    let config = (questions-config)
    let gate = $config.triage_gate
    # Send only the command line; captured output stays local.
    let state = {
        command: $command
        cwd: ($event.cwd? | default "" | str replace $env.HOME "~")
        exit_code: $exit_code
    }
    let response = (try {
        { ok: (ask $state $gate.questions $config.model "triage-gate") }
    } catch {|err|
        { error: $err.msg }
    })
    if ($response.error? != null) {
        return ({ route: "triage", reason: $"Jev unavailable: ($response.error)" } | to json -r)
    }
    let response = $response.ok

    let class = $response.answers.failure_class
    let needs_diagnosis = $response.answers.needs_diagnosis.noul
    let skip = (
        ($class.choice in $gate.skip_classes)
        and $class.confidence >= $gate.min_skip_confidence
        and $needs_diagnosis <= $gate.max_skip_needs_diagnosis
    )
    {
        route: (if $skip { "skip" } else { "triage" })
        class: $class.choice
        confidence: $class.confidence
        needs_diagnosis: $needs_diagnosis
        model: $response.model
    } | to json -r
}

# Classify Claude Code Bash tool calls before execution. The prefer-nushell
# hook pipes in each PreToolUse event its policy defers, and this emits a
# Claude Code hook decision as JSON. Any Jev failure is converted into an
# explicit user confirmation request.
def bash-ask [reason: string] {
    {
        hookSpecificOutput: {
            hookEventName: PreToolUse
            permissionDecision: ask
            permissionDecisionReason: $reason
        }
    }
}

def bash-guard [input: any] {
    let event = (parse-stdin $input)
    if ($event.tool_name? | default "") != "Bash" {
        return {}
    }
    let tool_input = ($event.tool_input? | default {})
    let command = ($tool_input.command? | default "")
    if ($command | str trim | is-empty) {
        return (bash-ask "The Bash command could not be inspected. Confirm before running it.")
    }
    if $command =~ $credential_pattern {
        return (bash-ask "This Bash command appears to assign a credential. Jev was not sent the command; confirm before running it.")
    }

    let config = (questions-config)
    let guard = $config.bash_guard
    let state = {
        bash_command: $command
        cwd: ($event.cwd? | default "" | str replace $env.HOME "~")
    }
    let result = (try {
        { response: (ask $state $guard.questions $config.model "bash-guard") }
    } catch {|err|
        { error: $err.msg }
    })
    if ($result.error? != null) {
        return (bash-ask $"Jev could not classify this Bash call: ($result.error). Confirm before running it.")
    }

    let rewrite = ($result.response.answers.nushell_rewrite.noul? | default 0)
    if $rewrite >= $guard.min_nushell_rewrite {
        return {
            hookSpecificOutput: {
                hookEventName: PreToolUse
                permissionDecision: deny
                permissionDecisionReason: $"Jev recommends Nushell \(p=($rewrite)\). Do not run this Bash call. Rewrite it as a Nushell pipeline and run it with the Nushell MCP tool \(mcp__plugin_hm_nushell__evaluate\). Without that tool, as in some subagents, page through files and saved tool results with the Read tool's offset and limit; `nu -c`, `cat`, `python3`, and every other Bash route are denied too. For large files, logs, or output, keep the data in a Nushell variable and follow the rlm skill instead of printing it."
            }
        }
    }
    bash-ask $"Jev determined Bash is appropriate \(Nushell rewrite p=($rewrite)\). Confirm before running this command."
}

def "main bash-guard" [] {
    let input = $in
    let output = (try {
        { result: (bash-guard $input) }
    } catch {|err|
        { error: $err.msg }
    })
    if ($output.error? != null) {
        print --stderr $"jev bash-guard: ($output.error)"
        return (bash-ask $"The Jev Bash guard could not inspect this command: ($output.error). Confirm before running it." | to json -r)
    }
    $output.result | to json -r
}

# Triage Claude Code desktop sessions: Jev reads how each one ended, and
# code checks what it names against jj, GitHub, and the system profile
# before deciding whether to archive it, close it out, or leave it running.

# Where the desktop app keeps session metadata and Claude Code transcripts.
def session-metadata-dir [] {
    let config = ($env.XDG_CONFIG_HOME? | default ($env.HOME | path join ".config"))
    $env.JEV_SESSION_METADATA_DIR? | default ($config | path join "Claude" "claude-code-sessions")
}

def transcript-dir [] {
    $env.JEV_TRANSCRIPT_DIR? | default ($env.CLAUDE_CONFIG_DIR? | default ($env.HOME | path join ".claude") | path join "projects")
}

# The desktop app's sessions, most recently active first.
def desktop-sessions [include_archived: bool] {
    glob $"(session-metadata-dir)/*/*/local_*.json"
    | each {|file| try { open $file } catch { null } }
    | compact
    | where {|meta| $include_archived or not ($meta.isArchived? | default false) }
    | each {|meta| {
        id: $meta.sessionId
        title: ($meta.title? | default "")
        cwd: ($meta.cwd? | default "")
        # Older sessions name their transcript after the app's own id.
        transcript: ($meta.cliSessionId? | default ($meta.sessionId | str replace "local_" ""))
        last_at: (($meta.lastActivityAt? | default 0 | into int) * 1_000_000 | into datetime)
    } }
    | sort-by last_at --reverse
}

# A message's prose, or "" for tool calls, tool results, and slash commands.
def message-text [content: any] {
    let text = if ($content | describe) == "string" { $content } else {
        $content | where {|block| ($block.type? | default "") == "text" } | get -o text | default [] | str join "\n"
    }
    if $text =~ '^\s*<(command-|local-command|task-notification|system-reminder)' { "" } else { $text | str trim }
}

def transcript-messages [transcript: string] {
    let file = (glob $"(transcript-dir)/*/($transcript).jsonl" | get -o 0)
    if $file == null { return [] }
    open --raw $file
    | lines
    | each {|line| try { $line | from json } catch { null } }
    | compact
    | where {|row| ($row.type? | default "") in [user assistant] and not ($row.isSidechain? | default false) }
    | each {|row| { role: $row.type, text: (message-text ($row.message?.content? | default "")) } }
}

# Lines that assign credentials never leave the machine.
def withhold-credentials [text: string] {
    $text | lines | each {|line|
        if $line =~ $credential_pattern { "[line withheld: credential assignment]" } else { $line }
    } | str join "\n"
}

def clip [text: string, chars: int] {
    if ($text | str length) <= $chars { $text } else { $text | str substring 0..($chars - 1) }
}

# How a session ended: what Jev is sent, plus the replies code scans.
def session-ending [messages: list, config: record] {
    let prose = ($messages | where text != "")
    let replies = ($prose | where role == assistant | get text)
    let last = ($messages | last 1)
    {
        empty: ($prose | is-empty)
        stopped_mid_turn: (($last | get -o 0.role) != "assistant" or ($last | get -o 0.text | default "") == "")
        last_user_message: (clip ($prose | where role == user | last 1 | get -o 0.text | default "") $config.max_user_chars)
        last_assistant_message: (clip ($replies | last 1 | get -o 0 | default "") $config.max_reply_chars)
        recent_replies: ($replies | last $config.recent_replies | str join "\n")
        all_replies: ($replies | str join "\n")
    }
}

# Facts about a session's repository, gathered once per repository.
def repo-facts [cwd: string] {
    let none = { jj: false, open_prs: null, in_flight: 0 }
    # A folder that is gone, or a machine without jj, has no facts to offer.
    let root = (try { ^jj root -R $cwd --ignore-working-copy | complete } catch { null })
    if ($cwd | is-empty) or $root == null or $root.exit_code != 0 {
        return $none
    }
    let prs = (try { do { cd $cwd; ^gh pr list --state open --json number } | complete } catch { { exit_code: 1 } })
    let branches = (^jj bookmark list -R $cwd --ignore-working-copy --all-remotes -T 'if(remote, if(remote != "git", if(name.starts_with("jj-"), name ++ "\n")))' | complete)
    {
        jj: true
        open_prs: (if $prs.exit_code == 0 { $prs.stdout | from json | get number } else { null })
        in_flight: ($branches.stdout | lines | uniq | length)
    }
}

# Change ids in `text` and whether each landed, is still open, or is empty;
# ids jj does not know, such as English words, are dropped.
def change-refs [text: string, cwd: string] {
    $text | parse -r '\b(?<id>[k-z]{8,12})\b' | get id | each { str substring 0..7 } | uniq | each {|id|
        let found = (^jj log -R $cwd --ignore-working-copy --no-graph -r $id -T 'if(immutable, "landed", if(empty, "empty", "open"))' | complete)
        if $found.exit_code == 0 { { ref: $id, status: ($found.stdout | str trim) } }
    } | compact
}

# Releases (YYYY.MM.DD.N) are tagged only after a topic lands on main.
def release-refs [text: string] {
    $text | parse -r '\b(?<tag>20\d\d\.\d\d\.\d\d\.\d+)\b' | get tag | uniq | each {|tag| { ref: $tag, status: "landed" } }
}

def pr-refs [text: string, open_prs: any] {
    $text | parse -r '(?:\bPRs?\s*|pull request\s*|pull/|#)#?(?<n>\d{2,5})\b' | get n | uniq | into int | each {|n|
        let status = if $open_prs == null { "unknown" } else if $n in $open_prs { "open" } else { "closed" }
        { ref: $"#($n)", status: $status }
    }
}

# The time the newest system generation was created, if any.
def last-switch [] {
    let links = (try { ls /nix/var/nix/profiles | where name =~ 'system-\d+-link$' } catch { [] })
    if ($links | is-empty) { null } else { $links | get modified | math max }
}

# Code owns the decision. `answers` holds Jev's judgments; `facts` what
# jj, GitHub, and the system profile say about the session.
def triage-decision [answers: record, facts: record, config: record] {
    let recent = $facts.recent_refs
    let refs_done = ($recent | is-not-empty) and ($recent | all {|r| $r.status in [landed closed] })
    let waiting = $answers.ending in [awaiting_decision awaiting_user_step waiting_on_job]
    let decide = {|decision, reason| { decision: $decision, reason: $reason } }

    let unlanded = ($facts.session_refs | where status == open | get ref)
    let open_prs = ($recent | where {|r| $r.status == open and ($r.ref | str starts-with "#") } | get ref)
    if ($unlanded | is-not-empty) or ($open_prs | is-not-empty) {
        return (do $decide "close out" $"unlanded: ($unlanded | append $open_prs | str join ' ')")
    }
    if $answers.ending == waiting_on_job and $facts.age > $config.job_settled_after and $facts.in_flight == 0 {
        return (do $decide archive "the job it waited on has ended; nothing is in flight")
    }
    if $waiting and $facts.age > $config.stale_after and ($refs_done or ($recent | is-empty) and $answers.delivery_only >= $config.min_delivery_only) {
        return (do $decide archive "stale, and everything it names has landed")
    }
    if $waiting and $refs_done and $answers.delivery_only >= $config.min_delivery_only {
        return (do $decide archive "the delivery it waited on has happened")
    }
    if ($answers.ending in [awaiting_user_step awaiting_decision finished]
        and $answers.activation >= $config.min_activation
        and $facts.switched_since
        and ($refs_done or $answers.delivery_only >= 0.7)) {
        return (do $decide archive "only an activation was left, and the system has switched since")
    }
    if $answers.ending == finished and ($answers.remaining < $config.finished_max_remaining or $refs_done) {
        return (do $decide archive "finished")
    }
    if $answers.ending != interrupted and $answers.remaining < $config.archive_max_remaining {
        return (do $decide archive "nothing remains")
    }
    if $answers.remaining < $config.ongoing_min_remaining {
        do $decide "close out" $"($answers.ending | str replace -a '_' ' ')"
    } else {
        do $decide ongoing $"($answers.ending | str replace -a '_' ' ')"
    }
}

def triage-session [session: record, repo: record, switched_at: any, config: record, model: string] {
    let row = { session: $session.id, title: $session.title, last_active: $session.last_at }
    let ending = (session-ending (transcript-messages $session.transcript) $config)
    if $ending.empty {
        return ($row | merge { decision: archive, ending: empty, reason: "no conversation" })
    }
    let state = {
        session: {
            folder: ($session.cwd | str replace $env.HOME "~")
            stopped_mid_turn: $ending.stopped_mid_turn
            last_user_message: (withhold-credentials $ending.last_user_message)
            last_assistant_message: (withhold-credentials $ending.last_assistant_message)
        }
    }
    let response = (try { { ok: (ask $state $config.questions $model "session-triage") } } catch {|err| { error: $err.msg } })
    if ($response.error? != null) {
        return ($row | merge { decision: unknown, ending: null, reason: $"Jev unavailable: ($response.error)" })
    }
    let found = $response.ok.answers
    let answers = {
        ending: $found.ending.choice
        delivery_only: $found.delivery_only.noul
        activation: $found.activation_step.noul
        remaining: $found.remaining_work.score
    }
    let recent = (
        if $repo.jj { change-refs $ending.recent_replies $session.cwd } else { [] }
        | append (release-refs $ending.recent_replies)
        | append (pr-refs $ending.recent_replies $repo.open_prs)
    )
    let facts = {
        recent_refs: $recent
        session_refs: (if $repo.jj { change-refs $ending.all_replies $session.cwd } else { [] })
        in_flight: $repo.in_flight
        age: ((date now) - $session.last_at)
        switched_since: ($switched_at != null and $session.last_at < $switched_at)
    }
    $row | merge { ending: $answers.ending } | merge (triage-decision $answers $facts $config)
}

# Sort the desktop app's sessions into archive, close out, and ongoing.
# Sends each session's last user message and final reply to Jev, never
# credential assignments; everything else stays local.
def "main session-triage" [
    ...sessions: string # Session ids (local_...); defaults to every active session
    --include-archived # Also triage archived sessions
    --json # Print JSON instead of a table
] {
    let all_config = (questions-config)
    let config = $all_config.session_triage
    let found = (desktop-sessions $include_archived)
    let chosen = if ($sessions | is-empty) { $found } else { $found | where id in $sessions }
    let repos = ($chosen | get cwd | uniq | each {|cwd| { cwd: $cwd, facts: (repo-facts $cwd) } })
    let switched_at = (last-switch)
    let rows = ($chosen | par-each --threads $config.parallel_requests {|session|
        let repo = ($repos | where cwd == $session.cwd | first | get facts)
        triage-session $session $repo $switched_at $config $all_config.model
    } | sort-by decision last_active)
    if $json { $rows | to json } else { $rows | select decision session title ending reason | table --index false }
}

def main [] {
    print "Usage: jev ask | jev classify-task | jev triage-gate | jev bash-guard | jev session-triage"
}
