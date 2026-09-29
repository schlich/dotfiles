#!/usr/bin/env -S nu --stdin

# Claude Code renders a Nushell MCP evaluation as a bare `input:` argument and
# a collapsed result. Show the full command before the call and, after it, a
# summary with the output's last lines as a `systemMessage`, which the user
# sees and the model does not. This hook only displays: it never decides, and any problem leaves
# it silent so the tool call proceeds exactly as it would without it.

const max_command_lines = 40
const max_text = 160
const preview_lines = 12
# Columns Claude Code spends before a message line: its gutter plus our indent.
const line_indent = 12
const fallback_width = 100

def emit [message: string] {
  print ({ systemMessage: $message } | to json --raw)
}

# The hook has no terminal of its own, but Claude Code, an ancestor process,
# does. Walk up to the first process attached to a pseudo-terminal and ask it
# for the width, so lines can be clipped instead of wrapping mid-table.
def terminal-width [] {
  mut pid = $nu.pid
  for _ in 1..8 {
    let tty = (try { ls -l $"/proc/($pid)/fd" | where target? =~ '^/dev/pts/' | get -o 0.target | default "" } catch { "" })
    if $tty != "" {
      let size = (try { ^stty -F $tty size | complete } catch { { exit_code: 1 } })
      if $size.exit_code == 0 {
        return (try { $size.stdout | split words | get 1 | into int } catch { $fallback_width })
      }
      return $fallback_width
    }
    let stat = (try { open --raw $"/proc/($pid)/stat" } catch { "" })
    if $stat == "" { return $fallback_width }
    $pid = ($stat | str replace --regex '^.*\) ' '' | split row ' ' | get 1 | into int)
  }
  $fallback_width
}

# Clip one line to `width` columns, never past max_text.
def clip-line [line: string, width: int] {
  let limit = ([$max_text ([$width 20] | math max)] | math min)
  if ($line | str length) > $limit {
    $"($line | str substring 0..<($limit - 1))…"
  } else {
    $line
  }
}

def line-width [] {
  ($env.DISPLAY_COLUMNS? | default $fallback_width) - $line_indent
}

def clip [text: string] {
  clip-line ($text | lines | get -o 0 | default "" | str trim) (line-width)
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

# The last few non-blank lines of some output, indented under the summary, so
# a finished command shows its outcome rather than only line counts.
def tail-preview [text: string, label: string = ""] {
  let all = ($text | lines | where ($it | str trim) != "")
  if ($all | is-empty) { return "" }
  let width = (line-width)
  let shown = ($all | last $preview_lines | each {|line| clip-line $line $width })
  let skipped = ($all | length) - ($shown | length)
  let header = if $label != "" { $"\n  ($label):" } else { "" }
  let gap = if $skipped > 0 { $"\n    … ($skipped) earlier lines" } else { "" }
  $"($header)($gap)\n($shown | each {|line| $'    ($line)' } | str join "\n")"
}

def describe-value [value: any] {
  let kind = ($value | describe | str replace --regex '<.*' '')
  match $kind {
    "nothing" => "no output"
    "string" => {
      let count = ($value | lines | length)
      if $count <= 1 { $"\"(clip $value)\"" } else { $"($count) lines(tail-preview $value)" }
    }
    "list" | "table" => {
      let count = ($value | length)
      let rows = if $count == 1 { "1 row" } else { $"($count) rows" }
      # Render only the last rows so a huge table stays within the hook timeout.
      $"($rows)(tail-preview ($value | last $preview_lines | table --expand | ansi strip))"
    }
    "record" => {
      let columns = ($value | columns)
      if ("exit_code" in $columns) and ("stdout" in $columns) {
        let stdout = ($value.stdout | into string)
        let stderr = ($value.stderr? | default "" | into string)
        let base = $"exit ($value.exit_code) · stdout ($stdout | lines | length) lines · stderr ($stderr | lines | length) lines"
        # A failure's cause is usually on stderr; a success's result on stdout.
        let err = if $value.exit_code != 0 { tail-preview $stderr "stderr" } else { "" }
        $"($base)(tail-preview $stdout 'stdout')($err)"
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
  let width = (line-width)
  let body = ($shown | enumerate | each {|line|
    let text = (clip-line $line.item $width)
    if $line.index == 0 { $text } else { $"    ($text)" }
  } | str join "\n")
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
  # Keep the directory on the summary line, above any output preview.
  let head = ($summary | lines | get -o 0 | default "")
  let preview = ($summary | lines | skip 1 | each {|line| $"\n($line)" } | str join)
  emit $"nu ✓($index)(elapsed $payload) · ($head)($place)($preview)"
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
    $env.DISPLAY_COLUMNS = (terminal-width)
    match ($payload.hook_event_name? | default "") {
      "PreToolUse" => { show-command $payload }
      "PostToolUse" => { show-result $payload }
      "PostToolUseFailure" => { show-failure $payload }
      _ => {}
    }
  }
}
