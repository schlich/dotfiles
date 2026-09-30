#!/usr/bin/env -S nu --stdin

# Learn from your answers to Claude Code permission dialogs which kinds of
# tool call you approve, and, for classes you promote, answer the dialog for
# you. The policy is modules/tooling/ai/trust-policy.nuon, the Jev questions
# are `route` in jev/questions.nuon, and `agent-trust report` shows what the
# ledger has learned.

# claude-code.nix replaces these with store paths; the AGENT_TRUST_*
# variables override them for tests.
const default_policy = "@policy@"
const default_questions = "@questions@"
const default_jev = "@jev@"

# Mirrors jev's credential filter: such calls are neither sent to Jev nor
# logged verbatim.
const credential_pattern = '(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*\s*='

def policy [] {
  open ($env.AGENT_TRUST_POLICY? | default $default_policy)
}

def state-dir [] {
  ($env.XDG_STATE_HOME? | default ($env.HOME | path join ".local" "state")) | path join "agent-trust"
}

def log-path [] {
  $env.AGENT_TRUST_LOG? | default (state-dir | path join "decisions.jsonl")
}

# A dialog leaves a marker named after its tool_use_id, so the PostToolUse
# hook logs only the runs that answer a dialog.
def marker-path [id: string] {
  state-dir | path join "pending" ($id | str replace --all --regex '[^A-Za-z0-9_-]' '')
}

# Logging must never change a decision, so failures go to stderr only.
def append-log [entry: record] {
  try {
    let path = (log-path)
    mkdir ($path | path dirname)
    $"($entry | to json --raw)\n" | save --append $path
  } catch {|err|
    print --stderr $"agent-trust: could not write the log: ($err.msg)"
  }
}

def load-log [] {
  let path = (log-path)
  if not ($path | path exists) {
    return []
  }
  open --raw $path | lines | where {|line| $line | str trim | is-not-empty } | each {|line| $line | from json }
}

# Hook runners spawn this script with a socket for stdin, and Linux cannot
# reopen a socket through /dev/stdin, so read the payload from `$in`. That
# requires running under `nu --stdin`.
def parse-payload [input: any] {
  if ($input | describe) == "nothing" {
    error make { msg: "no hook payload on stdin; run this hook with `nu --stdin`" }
  }
  # `from json` accepts bare words and empty input, so require an object.
  let payload = ($input | into string | from json)
  if not ($payload | describe | str starts-with "record") {
    error make { msg: $"hook payload is not a JSON object \(got ($payload | describe)\)" }
  }
  $payload
}

# What Jev sees and the floors match: the command, file path, or arguments,
# never file contents.
def summarize [tool: string, args: record] {
  let text = if $tool == "Bash" {
    $args.command? | default ""
  } else if $tool in [Edit Write MultiEdit NotebookEdit] {
    $args.file_path? | default ($args.notebook_path? | default "")
  } else if ($tool | str ends-with "nushell__evaluate") {
    $args.input? | default ""
  } else {
    $args | to json --raw
  }
  let text = ($text | into string)
  if ($text | str length) > 800 { $"($text | str substring 0..799)…" } else { $text }
}

# One-sided Wilson lower bound on the approval rate from weighted counts.
def wilson-lower [approved: float, total: float, z: float] {
  if $total <= 0 {
    return 0.0
  }
  let p = $approved / $total
  let z2 = $z * $z
  let spread = $z * (($p * (1 - $p) / $total + $z2 / (4 * $total * $total)) | math sqrt)
  ($p + $z2 / (2 * $total) - $spread) / (1 + $z2 / $total)
}

# Your answers to past dialogs, weighted by age. A dialog whose tool ran was
# approved; one with no run after `pending_minutes` was denied. Calls the
# hook approved itself are not evidence.
def ledger [entries: list, config: record] {
  let now = (date now)
  let ran = ($entries | where {|entry| $entry.event in [ran failed] } | get -o tool_use_id | uniq)
  $entries
  | where {|entry|
    $entry.event == "request" and not ($entry.enforced? | default false) and ($entry.class? | default null) != null
  }
  | each {|entry|
    let age = (($now - ($entry.ts | into datetime)) / 1day)
    let outcome = if ($entry.tool_use_id? | default null) in $ran {
      "approved"
    } else if $age * 1440 > $config.pending_minutes {
      "denied"
    } else {
      "pending"
    }
    {
      class: $entry.class
      decision: $entry.decision
      outcome: $outcome
      weight: (0.5 ** ($age / $config.half_life_days))
    }
  }
  | where outcome != "pending"
}

def trust [outcomes: list, class: string, z: float] {
  let rows = ($outcomes | where class == $class)
  if ($rows | is-empty) {
    return { samples: 0, trust: 0.0 }
  }
  let approved = ($rows | where outcome == "approved" | get weight | math sum)
  let total = ($rows | get weight | math sum)
  { samples: ($rows | length), trust: (wilson-lower $approved $total $z) }
}

def classify [tool: string, text: string, cwd: string] {
  let questions = (open ($env.AGENT_TRUST_QUESTIONS? | default $default_questions)).route.questions
  let jev = ($env.AGENT_TRUST_JEV? | default $default_jev)
  let request = { state: { tool_name: $tool, input: $text, cwd: $cwd }, questions: $questions }
  let result = ($request | to json --raw | run-external $jev "ask" | complete)
  if $result.exit_code != 0 {
    let detail = ($result.stderr | lines | where {|line| $line | str trim | is-not-empty } | get -o 0 | default "no output")
    error make { msg: $"jev ask exited ($result.exit_code): ($detail)" }
  }
  let answers = ($result.stdout | from json).answers
  {
    class: $answers.action_class.choice
    confidence: $answers.action_class.confidence
    intent: $answers.needs_user_intent.noul
  }
}

# What the hook would do with this dialog: `allow`, or `ask` with the reason
# the dialog stays yours.
def verdict [tool: string, text: string, cwd: string, config: record] {
  if $text =~ $credential_pattern {
    return { decision: "ask", reason: "credential assignment" }
  }
  let floor = ($config.floors | where {|rule| $tool =~ $rule.tool and $text =~ $rule.input } | get -o 0)
  if $floor != null {
    return { decision: "ask", reason: $"floor: ($floor.why)" }
  }
  let judged = (try {
    classify $tool $text $cwd
  } catch {|err|
    { error: $err.msg }
  })
  if ($judged.error? != null) {
    return { decision: "ask", reason: $"Jev unavailable: ($judged.error)" }
  }
  let tier = ($config.classes | get -o $judged.class | default "floor")
  let stats = (trust (ledger (load-log) $config) $judged.class $config.z)
  let needed = ($config.tiers | get -o $tier | default 1.0)
  let reason = if $tier == "floor" {
    "floor class"
  } else if $judged.intent >= $config.max_user_intent {
    "needs your intent"
  } else if $stats.samples < $config.min_samples {
    $"cold start: ($stats.samples) of ($config.min_samples) answers"
  } else if $stats.trust < $needed {
    $"trust ($stats.trust | math round --precision 3) below ($tier) tier ($needed)"
  } else {
    null
  }
  $judged
  | merge $stats
  | insert tier $tier
  | insert decision (if $reason == null { "allow" } else { "ask" })
  | insert reason ($reason | default $"trust ($stats.trust | math round --precision 3) clears ($tier) tier ($needed)")
}

def route [payload: record, config: record] {
  let tool = ($payload.tool_name? | default "")
  let tool_args = ($payload.tool_input? | default null)
  let text = (summarize $tool (if ($tool_args | describe | str starts-with "record") { $tool_args } else { {} }))
  let cwd = ($payload.cwd? | default "" | str replace $env.HOME "~")
  let id = ($payload.tool_use_id? | default null)
  let result = (verdict $tool $text $cwd $config)
  let enforced = (
    $config.mode == "enforce" and $result.decision == "allow" and ($result.class? in $config.enforce_classes)
  )

  append-log (
    {
      ts: (date now | format date "%+")
      event: "request"
      session_id: ($payload.session_id? | default null)
      tool_use_id: $id
      tool_name: $tool
      input: (if $text =~ $credential_pattern { "[redacted: credential assignment]" } else { $text | str substring 0..299 })
      cwd: $cwd
      permission_mode: ($payload.permission_mode? | default null)
      mode: $config.mode
    }
    | merge $result
    | insert enforced $enforced
  )
  if $id != null and not $enforced {
    let marker = (marker-path $id)
    mkdir ($marker | path dirname)
    touch $marker
  }

  if $enforced {
    print (
      {
        systemMessage: $"agent-trust approved ($tool) as ($result.class): ($result.reason)."
        hookSpecificOutput: {
          hookEventName: "PermissionRequest"
          decision: { behavior: "allow" }
        }
      } | to json --raw
    )
  }
}

# Claude Code PermissionRequest hook. Silent unless it approves the dialog;
# any failure leaves the dialog to you.
def "main permission-request" [] {
  let input = $in
  try {
    route (parse-payload $input) (policy)
  } catch {|err|
    print --stderr $"agent-trust: ($err.msg)"
  }
}

# Claude Code PostToolUse and PostToolUseFailure hook: record that a tool
# call which raised a dialog ran, which means you approved it.
def "main outcome" [] {
  let input = $in
  try {
    let payload = (parse-payload $input)
    let id = ($payload.tool_use_id? | default null)
    if $id == null {
      return
    }
    let marker = (marker-path $id)
    if not ($marker | path exists) {
      return
    }
    rm $marker
    append-log {
      ts: (date now | format date "%+")
      event: (if ($payload.hook_event_name? | default "") == "PostToolUseFailure" { "failed" } else { "ran" })
      tool_use_id: $id
    }
  } catch {|err|
    print --stderr $"agent-trust: ($err.msg)"
  }
}

# What the ledger has learned per class, and how often the shadow decision
# matched your answer.
def "main report" [
  --json # Print JSON for an agent instead of a table
] {
  let config = (policy)
  let entries = (load-log)
  let outcomes = (ledger $entries $config)
  let requests = ($entries | where event == "request")
  let classes = (
    $config.classes
    | columns
    | each {|class|
      let rows = ($outcomes | where class == $class)
      let stats = (trust $outcomes $class $config.z)
      {
        class: $class
        tier: ($config.classes | get $class)
        enforced: ($class in $config.enforce_classes)
        dialogs: ($requests | where {|entry| ($entry.class? | default null) == $class } | length)
        approved: ($rows | where outcome == "approved" | length)
        denied: ($rows | where outcome == "denied" | length)
        trust: ($stats.trust | math round --precision 3)
        would_allow: ($rows | where decision == "allow" | length)
        would_allow_approved: ($rows | where decision == "allow" and outcome == "approved" | length)
      }
    }
    | where dialogs > 0
  )
  let report = {
    mode: $config.mode
    log: (log-path)
    dialogs: ($requests | length)
    auto_approved: ($requests | where {|entry| $entry.enforced? | default false } | length)
    unclassified: (
      $requests
      | where {|entry| ($entry.class? | default null) == null }
      | group-by --to-table reason
      | each {|group| { reason: $group.reason, count: ($group.items | length) } }
    )
    classes: $classes
  }
  if $json { $report | to json } else { $report }
}

# Print the log file's path.
def "main path" [] {
  log-path
}

def main [] {
  print "Usage: agent-trust report [--json] | path | permission-request | outcome"
}
