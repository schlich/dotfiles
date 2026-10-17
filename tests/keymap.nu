# The Mod+Slash keymap overlay rendered headlessly with `tui debug`, against
# a small config.kdl so the layers and legends are fixed:
#   nu --no-config-file tests/keymap.nu niri/keymap.nu

const config = '
binds {
    // A comment line is not a bind.
    Mod+Return hotkey-overlay-title="Open a terminal" { spawn "foot"; }
    Mod+1 { focus-workspace "work"; }
    Mod+H { focus-column-left; }
    Mod+Shift+H { move-column-left; }
    Mod+Shift+E { quit; }
    Mod+Shift+Slash { show-hotkey-overlay; }
    Alt+Tab { focus-window-previous; }
}
'

def expect [name: string, actual: any, expected: any] {
  if $actual == $expected {
    print $"ok   ($name)"
    []
  } else {
    print $"FAIL ($name)\n     got      ($actual | to nuon)\n     expected ($expected | to nuon)"
    [$name]
  }
}

def main [script: path] {
  let script = ($script | path expand)
  let tmp = (mktemp --directory)
  let kdl = ($tmp | path join config.kdl)
  $config | save $kdl
  mut failures = []

  # `source` needs a literal path, so each replay runs in its own nu.
  let replay = {|keys: list, size: list|
    let code = $"source '($script)'
      keymap-tui \(keymap-layers '($kdl)'\) \(parse-rows\)
      | tui debug --keys ($keys | to nuon) --size ($size | to nuon)
      | select page action focused pages screen values
      | rename --column { values: filter } | update filter { get filter }
      | to nuon"
    let run = (^nu --no-config-file -c $code | complete)
    if $run.exit_code != 0 { error make --unspanned { msg: $"keymap-tui failed:\n($run.stderr)" } }
    $run.stdout | from nuon
  }
  let wide = [140 40]

  let start = (do $replay [] $wide)
  $failures = ($failures | append (expect "a page per layer, most binds first" ($start.pages | get title) ["1 Mod" "2 Mod+Shift" "3 Alt"]))
  $failures = ($failures | append (expect "opens on the first layer's legend" [$start.page $start.focused $start.action] [0 normal-1 render]))
  $failures = ($failures | append (expect "the keyboard is drawn" ($start.screen | str contains "Esc       F1   F2") true))
  $failures = ($failures | append (expect "the preview names the highlighted chord" ($start.screen | str contains "┌ Mod+1 ─") true))
  $failures = ($failures | append (expect "hotkey-overlay-title names a bind" ($start.screen | str contains "Open a terminal") true))
  $failures = ($failures | append (expect "the status bar names the keys" ($start.screen | str contains "1-9 [ ] layer · ↑↓ bind · / filter, Esc back · q/Esc close") true))
  $failures = ($failures | append (expect "the status bar shows the mode and layer" ($start.screen | str contains "focus:normal-1  page:1/3 1 Mod") true))

  let digit = (do $replay ['2'] $wide)
  $failures = ($failures | append (expect "a digit picks a layer" [$digit.page $digit.focused] [1 normal-2]))
  $failures = ($failures | append (expect "the legend follows the layer" ($digit.screen | str contains "move column left") true))
  let stepped = (do $replay [']' ']'] $wide)
  $failures = ($failures | append (expect "] steps to the next layer" $stepped.page 2))
  let down = (do $replay ['2' down] $wide)
  $failures = ($failures | append (expect "the arrows move through the legend" ($down.screen | str contains "┌ Mod+Shift+H ─") true))

  let filtered = (do $replay ['2' '/' 'type:quit'] $wide)
  $failures = ($failures | append (expect "/ focuses the filter" [$filtered.focused $filtered.filter] [filter quit]))
  $failures = ($failures | append (expect "the filter narrows the legend" [($filtered.screen | str contains "table (1)") ($filtered.screen | str contains "move column left")] [true false]))
  $failures = ($failures | append (expect "the status bar shows the filter mode" ($filtered.screen | str contains "focus:filter  filter:quit") true))
  let cleared = (do $replay ['/' 'type:quit' esc] $wide)
  $failures = ($failures | append (expect "Esc clears the filter" [$cleared.focused $cleared.filter] [filter ""]))
  let back = (do $replay ['/' 'type:quit' esc esc] $wide)
  $failures = ($failures | append (expect "Esc again returns to normal" [$back.focused $back.action] [normal-1 render]))

  $failures = ($failures | append (expect "q closes" (do $replay ['2' q] $wide).action quit))
  $failures = ($failures | append (expect "Esc closes from normal" (do $replay ['/' esc esc esc] $wide).action quit))
  $failures = ($failures | append (expect "q types into the filter" (do $replay ['/' q] $wide).filter q))

  let narrow = (do $replay [] [80 30])
  $failures = ($failures | append (expect "a narrow pane asks for more width" ($narrow.screen | str contains "Widen the window to 115 columns") true))

  rm --recursive $tmp
  if ($failures | is-not-empty) {
    error make --unspanned { msg: $"($failures | length) keymap checks failed: ($failures | str join ', ')" }
  }
}
