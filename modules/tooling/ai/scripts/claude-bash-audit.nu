# Summarize the Claude Code Bash request log written by prefer-nushell-bash.nu
# so repeated Bash use cases can be fixed in the agent instructions or in
# bash-policy.nuon. The bash-feedback skill drives the review loop.

def state-dir [] {
  ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state")) | path join "claude-code"
}

def log-path [] {
  $env.CLAUDE_BASH_LOG? | default (state-dir | path join "bash-requests.jsonl")
}

def watermark-path [] {
  state-dir | path join "bash-review.nuon"
}

# Use cases already reviewed (`known`) or already raised by the Stop hook
# (`prompted`), keyed by `use-case-key`.
def use-cases-path [] {
  state-dir | path join "bash-use-cases.nuon"
}

def load-use-cases [] {
  let path = (use-cases-path)
  if ($path | path exists) { open $path } else { { known: [], prompted: [] } }
}

def use-case-key [entry: record] {
  $"($entry.rule) · ($entry.programs | get -o 0 | default '')"
}

# A bare shell no-op such as `true` or `:`, which harnesses send to probe
# the Bash tool. It carries no use case, so the Stop hook never raises it.
def noop-command [command: string] {
  ($command | str trim) in ["true" ":"]
}

def load-log [] {
  let path = (log-path)
  if not ($path | path exists) {
    return []
  }
  open --raw $path | lines | where {|line| $line | str trim | is-not-empty } | each {|line| $line | from json }
}

def reviewed-until [] {
  let path = (watermark-path)
  if ($path | path exists) { (open $path).reviewed_until | into datetime } else { null }
}

# Requests since the last review, each with the outcome recorded after it.
def pending [all: bool] {
  let entries = (load-log)
  let since = (if $all { null } else { reviewed-until })
  let outcomes = (
    $entries
    | where event in [ran failed]
    | where tool_use_id != null
    | reduce --fold {} {|entry, acc| $acc | upsert $entry.tool_use_id $entry.event }
  )
  $entries
  | where event == request
  | where {|entry| $since == null or ($entry.ts | into datetime) > $since }
  | each {|entry|
    let outcome = (if $entry.decision == deny {
      "denied"
    } else if $entry.tool_use_id == null {
      "unknown"
    } else {
      $outcomes | get -o $entry.tool_use_id | default "not run"
    })
    $entry | insert outcome $outcome
  }
}

# Group pending requests into use cases: rule plus leading program.
def "main report" [
  --all # Include requests that were already reviewed
  --json # Print JSON for an agent instead of a table
] {
  let requests = (pending $all)
  let clusters = (
    $requests
    | insert program {|entry| $entry.programs | get -o 0 | default "" }
    | group-by --to-table rule program
    | each {|group|
      {
        rule: $group.rule
        program: $group.program
        count: ($group.items | length)
        sessions: ($group.items | get session_id | uniq | length)
        outcomes: ($group.items | get outcome | uniq | str join ", ")
        examples: ($group.items | get command | uniq | first 5 | each {|command|
          if ($command | str length) > 200 { $"($command | str substring 0..199)…" } else { $command }
        })
      }
    }
    | sort-by count --reverse
  )
  let report = {
    since: (if $all { null } else { reviewed-until })
    requests: ($requests | length)
    denied: ($requests | where decision == deny | length)
    deferred: ($requests | where decision == defer | length)
    ran: ($requests | where outcome in [ran failed] | length)
    clusters: $clusters
  }
  if $json { $report | to json } else { $report }
}

# Record that every request logged so far, and its use case, was reviewed.
def "main mark-reviewed" [] {
  let entries = (load-log)
  let last = ($entries | get -o ts | last | default (date now | format date "%+"))
  let keys = ($entries | where event == request | each {|entry| use-case-key $entry })
  let state = (load-use-cases)
  let known = ($state.known | append $keys | uniq)
  mkdir (state-dir)
  { reviewed_until: $last } | save --force (watermark-path)
  { known: $known, prompted: ($state.prompted | where {|key| $key not-in $known }) } | save --force (use-cases-path)
  print $"Marked Bash requests through ($last) as reviewed."
}

# Claude Code Stop hook: when this session logged a Bash use case that was
# never reviewed or raised before, keep the agent going to run the
# bash-feedback skill for it. Each use case is raised once.
def "main stop-hook" [] {
  let input = $in
  let result = (try {
    let payload = ($input | into string | from json)
    let session = ($payload.session_id? | default null)
    let skip = (
      ($payload.stop_hook_active? | default false)
      or ($env.CLAUDE_BASH_FEEDBACK? | default "") == "off"
      or $session == null
    )
    if $skip {
      return
    }
    let state = (load-use-cases)
    let seen = ($state.known | append $state.prompted)
    let fresh = (
      load-log
      | where {|entry| $entry.event == "request" and $entry.session_id? == $session }
      | where {|entry| not (noop-command $entry.command) }
      | each {|entry| { key: (use-case-key $entry), command: $entry.command } }
      | where {|case| $case.key not-in $seen }
      | uniq-by key
    )
    if ($fresh | is-empty) {
      return
    }
    mkdir (state-dir)
    $state | update prompted ($state.prompted | append $fresh.key) | save --force (use-cases-path)
    let listing = ($fresh | each {|case| $"- ($case.key), e.g. `($case.command | str substring 0..119)`" } | str join "\n")
    {
      decision: "block"
      reason: $"This session logged Bash use cases that have never been reviewed:\n($listing)\nBefore stopping, run the bash-feedback skill for only these use cases: propose agent-instruction or bash-policy.nuon changes and wait for the user's approval before editing the dotfiles repository. If the user declines or is busy, stop; the use cases remain in `claude-bash-audit report`."
    } | to json --raw
  } catch {|err|
    print --stderr $"claude-bash-audit stop-hook: ($err.msg)"
  })
  if $result != null {
    print $result
  }
}

# Print the log file's path.
def "main path" [] {
  log-path
}

def main [] {
  print "Usage: claude-bash-audit report [--all] [--json] | mark-reviewed | stop-hook | path"
}
