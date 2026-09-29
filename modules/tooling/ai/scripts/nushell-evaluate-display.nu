#!/usr/bin/env -S nu --stdin

# Claude Code renders a Nushell MCP evaluation as a bare `input:` argument and
# a collapsed result. Show the full command before the call and a one-line
# summary after it as a `systemMessage`, which the user sees and the model
# does not. This hook only displays: it never decides, and any problem leaves
# it silent so the tool call proceeds exactly as it would without it.

const max_command_lines = 40
const max_text = 160

def emit [message: string] {
  print ({ systemMessage: $message } | to json --raw)
}

def clip [text: string] {
  let line = ($text | lines | get -o 0 | default "" | str trim)
  if ($line | str length) > $max_text {
    $"($line | str substring 0..<($max_text - 1))…"
  } else {
    $line
  }
}

def home-relative [path: string] {
  let home = ($env.HOME? | default "")
  if $home != "" and ($path == $home or ($path | str starts-with $"($home)/")) {
    $"~($path | str substring ($home | str length)..)"
  } else {
    $path
  }
}

# The server replies with a JSON (or NUON) record; parse either.
def parse-reply [text: string] {
  try { $text | from json } catch { try { $text | from nuon } catch { $text } }
}

# Claude Code passes an MCP result as its content blocks; accept a bare string
# or a `{content: [...]}` record as well.
def response-text [response: any] {
  let blocks = match ($response | describe | str replace --regex '<.*' '') {
    "string" => { return $response }
    "record" => ($response | get -o content | default [])
    "list" | "table" => $response
    _ => []
  }
  $blocks
  | where {|block| ($block | describe | str starts-with "record") and ($block.type? == "text") }
  | get text
  | str join "\n"
}

def describe-value [value: any] {
  let kind = ($value | describe | str replace --regex '<.*' '')
  match $kind {
    "nothing" => "no output"
    "string" => {
      let count = ($value | lines | length)
      if $count <= 1 { $"\"(clip $value)\"" } else { $"($count) lines" }
    }
    "list" | "table" => {
      let count = ($value | length)
      if $count == 1 { "1 row" } else { $"($count) rows" }
    }
    "record" => {
      let columns = ($value | columns)
      if ("exit_code" in $columns) and ("stdout" in $columns) {
        let stdout = ($value.stdout | into string | lines | length)
        let stderr = ($value.stderr? | default "" | into string)
        let base = $"exit ($value.exit_code) · stdout ($stdout) lines · stderr ($stderr | lines | length) lines"
        if $value.exit_code != 0 and ($stderr | str trim) != "" {
          $"($base) · (clip $stderr)"
        } else {
          $base
        }
      } else {
        let shown = ($columns | first 6 | str join ", ")
        let more = if ($columns | length) > 6 { ", …" } else { "" }
        $"record {($shown)($more)}"
      }
    }
    _ => $"($kind): (clip ($value | to nuon))"
  }
}

def elapsed [payload: record] {
  let ms = ($payload.duration_ms? | default null)
  if $ms == null { "" } else { $" · ($ms | into int | into duration --unit ms)" }
}

def show-command [payload: record] {
  let command = ($payload.tool_input?.input? | default "")
  if ($command | str trim) == "" { return }
  let all = ($command | str trim | lines)
  let shown = ($all | first $max_command_lines)
  let hidden = ($all | length) - ($shown | length)
  let body = ($shown | enumerate | each {|line| if $line.index == 0 { $line.item } else { $"    ($line.item)" } } | str join "\n")
  let tail = if $hidden > 0 { $"\n    … ($hidden) more lines" } else { "" }
  emit $"nu ▸ ($body)($tail)"
}

def show-result [payload: record] {
  let reply = (parse-reply (response-text ($payload.tool_response? | default null)))
  if not ($reply | describe | str starts-with "record") {
    emit $"nu ✓(elapsed $payload) · (describe-value $reply)"
    return
  }
  let index = if $reply.history_index? != null { $" #($reply.history_index)" } else { "" }
  let summary = if $reply.note? != null { clip ($reply.note | into string) } else { describe-value ($reply.output? | default null) }
  let cwd = ($reply.cwd? | default "")
  let place = if $cwd != "" and $cwd != ($payload.cwd? | default "") { $" · in (home-relative $cwd)" } else { "" }
  emit $"nu ✓($index)(elapsed $payload) · ($summary)($place)"
}

def show-failure [payload: record] {
  if ($payload.is_interrupt? | default false) {
    emit $"nu ⏹ interrupted(elapsed $payload)"
    return
  }
  let error = (parse-reply ($payload.error? | default "" | into string))
  let message = if ($error | describe | str starts-with "record") {
    let label = ($error.labels? | default [] | get -o 0.text | default "")
    let msg = ($error.msg? | default ($error | to nuon) | str trim --right --char ".")
    if $label != "" and $label != $msg { $"($msg): ($label)" } else { $msg }
  } else {
    $error
  }
  emit $"nu ✗(elapsed $payload) · (clip ($message | into string))"
}

def main [] {
  let input = $in
  try {
    let payload = ($input | into string | from json)
    match ($payload.hook_event_name? | default "") {
      "PreToolUse" => { show-command $payload }
      "PostToolUse" => { show-result $payload }
      "PostToolUseFailure" => { show-failure $payload }
      _ => {}
    }
  }
}
