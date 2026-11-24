# Each tool's documented modes, entered one key at a time in a terminal kept
# by nu_plugin_ghostty. After every key the mode label must name the mode, the
# hint line must list the keys documented for it (and none it must not
# offer), and Esc, or the key that entered a mode, must bring back the base
# mode. Bombadil's specifications (tests/bombadil) explore the same programs
# at random; this follows each one's documentation exactly.
#
#   nu --no-config-file --plugins '[PLUGIN]' mode-hints.nu CASE COMMAND...

# Each case's first step is the base mode, which every tool names NORMAL.
# Each step presses a `key` (a browser KeyboardEvent.code, such as Escape or
# Enter) or types `text`, then expects `mode` on the mode row (`shown` when
# any label will do), every key in `keys` among the hints, and none of
# `absent`. A hint's key may name several, such as `j/k` or `esc/←/h`.
const CASES = {
  # Fieldnotes' README, "Modes and keys": the badge sits on the row above the
  # hint line. CONFIRM opens only on a failed CI run, which an offline build
  # never has.
  fieldnotes: {
    mode_row: 2
    steps: [
      { mode: NORMAL, keys: [j k ⏎ / tab r R q] }
      { text: "/", mode: FILTER, keys: [⏎ esc], absent: [q] }
      { key: Escape, mode: NORMAL }
      { key: Enter, mode: DETAIL, keys: [esc j k J K r] }
      { key: Escape, mode: NORMAL }
      { key: Enter, mode: DETAIL }
      { key: Enter, mode: NORMAL }
    ]
  }
  # jjui draws its mode at the start of the hint line. It calls its base mode
  # `revisions`, and its help (`?`) and command prompt (`:`) show no mode, so
  # this case fails until jjui follows the rule; it reports from remoteChecks
  # without gating a landing.
  jjui: {
    mode_row: 1
    steps: [
      { mode: NORMAL, keys: [k j] }
      { text: r, mode: rebase, keys: [enter esc] }
      { key: Escape, mode: NORMAL }
      { text: l, mode: details, keys: [esc] }
      { key: Escape, mode: NORMAL }
      { text: "?", shown: true }
      { key: Escape, mode: NORMAL }
      { text: ":", shown: true, keys: [esc enter] }
      { key: Escape, mode: NORMAL }
    ]
  }
}

# Decode the HTML entities the plugin writes, numeric ones included.
def unescape []: string -> string {
  let text = $in
  $text | parse --regex '&#(?<n>\d+);' | get n | uniq
  | reduce --fold $text {|n, acc| $acc | str replace --all $"&#($n);" (char --integer ($n | into int)) }
  | str replace --all '&lt;' '<' | str replace --all '&gt;' '>' | str replace --all '&quot;' '"'
  | str replace --all '&#39;' "'" | str replace --all '&amp;' '&'
}

# The screen's rows, bottom row last, each a list of runs {text, bold}. The
# plugin writes a styled run as an inline div and unstyled text bare.
def screen-runs [t: int] {
  let info = ($t | ghostty info)
  $t | ghostty window ([($info.total - $info.rows) 0] | math max) $info.rows | get html
  | str replace --regex '^<div style="[^"]*">' '' | str replace --regex '</div>\s*$' ''
  | lines
  | each {|row|
      $row
      | parse --regex '<div style="(?<style>[^"]*)">(?<text>[^<]*)</div>|(?<bare>[^<]+)'
      | each {|r|
          if $r.bare != null {
            { text: ($r.bare | unescape), bold: false }
          } else {
            { text: ($r.text | unescape), bold: ($r.style =~ 'font-weight: bold') }
          }
        }
      | where ($it.text | str trim) != ''
    }
}

# The mode label and the hints, read from the bottom of the screen: the mode
# is the first bold run on the row `mode_row` rows up, and the hint line, the
# bottom row, alternates keys and their labels after it.
def read-state [t: int, mode_row: int] {
  let rows = (screen-runs $t)
  let at = (($rows | length) - $mode_row)
  let mode_runs = if $at >= 0 { $rows | get $at } else { [] }
  let badge = ($mode_runs | enumerate | where item.bold | get --optional 0)
  let line = ($rows | last | default [])
  let after = if $mode_row == 1 and $badge != null { $line | skip ($badge.index + 1) } else { $line }
  let hints = ($after | chunks 2 | where ($it | length) == 2 | each {|pair|
    { key: ($pair.0.text | str trim), label: ($pair.1.text | str trim | str trim --right --char '•' | str trim) }
  })
  {
    mode: (if $badge == null { null } else { $badge.item.text | str trim })
    hints: $hints
    line: ($line | get text | each { str trim } | str join ' ')
  }
}

# The keys a hint names: `j/k` is j and k, while `/` alone is the slash key.
def key-names [key: string] {
  if $key == "/" { ["/"] } else { $key | split row "/" | each { str trim } | where $it != "" }
}

# Wait until the screen has not changed for `quiet`, at most `limit`.
def settle [t: int, --quiet: duration = 500ms, --limit: duration = 15sec] {
  let deadline = ((date now) + $limit)
  mut last = ($t | ghostty info | get seq)
  mut since = (date now)
  while (date now) < $deadline {
    sleep 100ms
    let seq = ($t | ghostty info | get seq)
    if $seq != $last {
      $last = $seq
      $since = (date now)
    } else if ((date now) - $since) > $quiet {
      break
    }
  }
}

# The problems with one state against its step's expectations.
def problems [step: record, state: record] {
  let named = ($state.hints | each { key-names $in.key } | flatten)
  let expected = ($step.mode? | default null)
  let mode_problem = if $expected != null {
    if $state.mode != $expected { [$"mode is ($state.mode | to nuon), expected ($expected)"] } else { [] }
  } else if ($step.shown? | default false) and $state.mode == null {
    ["no mode is shown"]
  } else { [] }
  let missing = ($step.keys? | default [] | where $it not-in $named)
  let offered = ($step.absent? | default [] | where $it in $named)
  $mode_problem
  | append (if ($missing | is-empty) { [] } else { [$"hints lack ($missing | str join ' ')"] })
  | append (if ($offered | is-empty) { [] } else { [$"hints offer ($offered | str join ' '), which does not work here"] })
}

# --wrapped passes the command's own flags, such as env's -C, through.
def --wrapped main [case: string, ...command: string] {
  # Nushell stops an idle plugin, and its terminals end with it.
  $env.config.plugin_gc.plugins.ghostty = { enabled: false }
  let spec = ($CASES | get $case)
  # The plugin runs programs in its own directory, so start this one here.
  let t = (ghostty spawn [env -C (pwd) ...$command] --cols 120 --rows 40)

  # The program has started once it shows a mode.
  let deadline = ((date now) + 60sec)
  while (read-state $t $spec.mode_row).mode == null and (date now) < $deadline and ($t | ghostty info).alive {
    sleep 250ms
  }
  settle $t --quiet 1sec

  mut failures = []
  for step in ($spec.steps | enumerate) {
    let s = $step.item
    let pressed = if ($s.key? != null) { $s.key } else if ($s.text? != null) { $s.text } else { "(start)" }
    if $s.key? != null { $t | ghostty key $s.key }
    if $s.text? != null { $t | ghostty input $s.text }
    settle $t
    let state = (read-state $t $spec.mode_row)
    let found = (problems $s $state)
    let name = $"($case) step ($step.index + 1), ($pressed)"
    if ($found | is-empty) {
      print $"ok   ($name)"
    } else {
      print $"FAIL ($name): ($found | str join '; ')\n     hint line: ($state.line)"
      $failures = ($failures | append $name)
    }
  }
  $t | ghostty close
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) of ($spec.steps | length) mode checks failed for ($case)" }
  }
}
