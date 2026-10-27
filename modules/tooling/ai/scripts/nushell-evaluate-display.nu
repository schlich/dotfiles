#!/usr/bin/env -S nu --stdin

# The nushell-cards mod draws each Nushell MCP evaluation as a card titled by
# its `# comment`, with the head of its source, so this hook never repeats the
# command. After the call it reports, as a one-line `systemMessage` the user
# sees and the model does not, only what the collapsed result hides: a
# failure, an interruption, or a slow command's history index, duration, and
# size. This hook only displays: it never decides, and any problem leaves it
# silent so the tool call proceeds exactly as it would without it.

# Report a successful evaluation only when it took at least this long.
const slow_ms = 5000
const max_text = 160
# Columns Claude Code spends before a message line: its gutter plus our indent.
const line_indent = 12
const fallback_width = 100

def emit [message: string] {
  print ({ systemMessage: $message } | to json --raw)
}

def in-desktop-app [] {
  ($env.CLAUDE_CODE_ENTRYPOINT? | default "") == "claude-desktop"
}

# The hook has no terminal of its own, but Claude Code, an ancestor process,
# does. Walk up to the first process attached to a pseudo-terminal and ask it
# for the width, so a line can be clipped instead of wrapping.
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

# The first line of some text, clipped to the terminal and never past max_text.
def clip [text: string] {
  let line = ($text | lines | get -o 0 | default "" | str trim)
  let width = ($env.DISPLAY_COLUMNS? | default $fallback_width) - $line_indent
  let limit = ([$max_text ([$width 20] | math max)] | math min)
  if ($line | str length) > $limit {
    $"($line | str substring 0..<($limit - 1))…"
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

# A value's size in a few words: the result itself is one keypress away.
def size-of [value: any] {
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
        let stderr = ($value.stderr? | default "" | into string | lines | where ($it | str trim) != "")
        let cause = if $value.exit_code != 0 and ($stderr | is-not-empty) { $": (clip ($stderr | last))" } else { "" }
        $"exit ($value.exit_code)($cause)"
      } else {
        $"record of ($columns | length) fields"
      }
    }
    _ => $kind
  }
}

def elapsed [payload: record] {
  let ms = ($payload.duration_ms? | default null)
  if $ms == null { "" } else { $" · ($ms | into int | into duration --unit ms)" }
}

def show-result [payload: record] {
  if ($payload.duration_ms? | default 0) < $slow_ms { return }
  let reply = (parse-reply (response-text ($payload.tool_response? | default null)))
  if not ($reply | describe | str starts-with "record") {
    emit $"nu ✓(elapsed $payload) · (size-of $reply)"
    return
  }
  let index = if $reply.history_index? != null { $" #($reply.history_index)" } else { "" }
  let summary = if $reply.note? != null { "output truncated" } else { size-of ($reply.output? | default null) }
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
    # The desktop app has no terminal to measure; its notices use the fallback.
    $env.DISPLAY_COLUMNS = if (in-desktop-app) { $fallback_width } else { terminal-width }
    match ($payload.hook_event_name? | default "") {
      "PostToolUse" => { show-result $payload }
      "PostToolUseFailure" => { show-failure $payload }
      _ => {}
    }
  }
}
