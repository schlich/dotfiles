# An emoji keyboard of the niri binds (Mod+Slash, `session.nu keymap`).
#
# Reads the `binds { }` block of config.kdl, groups binds into layers by their
# modifiers, and draws one layer at a time as an ANSI keyboard: the main block,
# the navigation cluster, and the numpad that holds the Johnny Decimal grid.
# Each bound key shows the emoji of its action from keymap-emoji.nuon, and a
# legend below names every bind of the layer, including mouse and media binds
# that have no keycap. A key bound twice in one layer shows 💥.
#
# Tab or the arrows switch layers, a digit picks one, and q or Esc closes.

# Keyboard rows, one string per row. Each token is `keysym[=Label][:width]`
# in key units, and `_:width` is a gap. Keysyms are XKB names, lower-cased as
# niri matches them case-insensitively.
const rows = [
  "escape=Esc _:1 f1=F1 f2=F2 f3=F3 f4=F4 _:0.5 f5=F5 f6=F6 f7=F7 f8=F8 _:0.5 f9=F9 f10=F10 f11=F11 f12=F12 _:0.5 print=Prt scroll_lock=Scr pause=Pau"
  "grave=` 1 2 3 4 5 6 7 8 9 0 minus=- equal== backspace=Bksp:2 _:0.5 insert=Ins home=Home page_up=PgUp _:0.5 num_lock=Num kp_divide=/ kp_multiply=* kp_subtract=-"
  "tab=Tab:1.5 q w e r t y u i o p bracketleft=[ bracketright=] backslash=\\:1.5 _:0.5 delete=Del end=End page_down=PgDn _:0.5 kp_7=7 kp_8=8 kp_9=9 kp_add=+"
  "caps_lock=Caps:1.75 a s d f g h j k l semicolon=; apostrophe=' return=Enter:2.25 _:4 kp_4=4 kp_5=5 kp_6=6"
  "shift_l=Shift:2.25 z x c v b n m comma=, period=. slash=/ shift_r=Shift:2.75 _:1.5 up=↑ _:1.5 kp_1=1 kp_2=2 kp_3=3 kp_enter=Ent"
  "control_l=Ctrl:1.25 super_l=Mod:1.25 alt_l=Alt:1.25 space=Space:6.25 alt_r=Alt:1.25 super_r=Mod:1.25 menu=Menu:1.25 control_r=Ctrl:1.25 _:0.5 left=← down=↓ right=→ _:0.5 kp_0=0:2 kp_decimal=."
]

const unit = 5
const modifier_order = [Mod Ctrl Shift Alt]
const modifier_keys = {
  Mod: [super_l super_r]
  Ctrl: [control_l control_r]
  Shift: [shift_l shift_r]
  Alt: [alt_l alt_r]
}

const style = {
  frame: { fg: "#7f8490" }
  bound: { fg: "#e6e6e6", bg: "#3b4252" }
  free: { fg: "#5c6370", bg: "#23272e" }
  held: { fg: "#1d2021", bg: "#e5c07b", attr: b }
  tab: { fg: "#7f8490" }
  active: { fg: "#1d2021", bg: "#61afef", attr: b }
}

def paint [name: string, text: string] {
  $"(ansi --escape ($style | get $name))($text)(ansi reset)"
}

# Columns are rounded from each key's running start, so fractional widths
# never drift the rows out of line.
def parse-rows [] {
  $rows | each {|row|
    let keys = (
      $row | split row ' ' | where $it != '' | each {|token|
        let key = ($token | parse --regex '^(?<sym>[^=:]+)(?:=(?<label>[^:]*))?(?::(?<units>[\d.]+))?$' | get 0)
        {
          sym: $key.sym
          label: (if ($key.label | is-empty) { $key.sym | str upcase } else { $key.label })
          units: (if ($key.units | is-empty) { 1.0 } else { $key.units | into float })
        }
      }
    )
    let edges = ($keys | get units | reduce --fold [0.0] {|units, acc| $acc | append (($acc | last) + $units) })
    $keys | enumerate | each {|key|
      let start = (($edges | get $key.index) * $unit | math round)
      let end = (($edges | get ($key.index + 1)) * $unit | math round)
      $key.item | reject units | insert cols ($end - $start | into int)
    }
  }
}

# `spawn-sh "exec nu \"$HOME/.config/niri/session.nu\" grid left";` reads
# `run session grid left`.
def normalise [action: string] {
  $action
  | str trim
  | str trim --right --char ';'
  | str replace --all '\"' '"'
  | str replace --all '"' ''
  | str replace --regex 'exec nu \$HOME/\.config/niri/session\.nu' 'session'
  | str replace --regex '^spawn(-sh)? ' 'run '
}

def load-binds [config: path, emoji: list] {
  let lines = (open --raw $config | lines)
  let start = ($lines | enumerate | where item =~ '^binds\s*\{' | get 0.index)
  let end = ($lines | enumerate | skip ($start + 1) | where item =~ '^\}' | get 0.index)
  $lines
  | slice ($start + 1)..($end - 1)
  | where {|line| not ($line | str trim | str starts-with '/') }
  | parse --regex '^\s*(?<combo>[\w+]+)\s*(?<props>[^{]*)\{(?<action>.*)\}\s*$'
  | each {|bind|
    let parts = ($bind.combo | split row '+')
    let mods = (
      $parts | drop 1
      | each {|mod| match $mod { 'Super' => 'Mod', 'Control' => 'Ctrl', _ => $mod } }
      | sort-by {|mod| $modifier_order | enumerate | where item == $mod | get 0?.index | default 99 }
    )
    let command = (normalise $bind.action)
    let title = ($bind.props | parse --regex 'hotkey-overlay-title="(?<t>[^"]*)"' | get 0?.t)
    {
      layer: (if ($mods | is-empty) { "No modifier" } else { $mods | str join '+' })
      mods: $mods
      key: ($parts | last)
      sym: ($parts | last | str downcase)
      emoji: ($emoji | where {|entry| $command =~ $entry.action } | get 0?.emoji | default '🔹')
      title: ($title | default ($command | str replace --all '-' ' '))
    }
  }
}

def layer-names [binds: list] {
  let present = ($binds | get layer | uniq)
  let preferred = [Mod Mod+Shift Mod+Ctrl Mod+Alt] | where $it in $present
  let rest = (
    $binds | where layer not-in $preferred | group-by layer
    | transpose layer binds | sort-by {|l| $l.binds | length } --reverse | get layer
  )
  $preferred | append $rest
}

def keycap [key: record, layer: list, held: list] {
  let width = $key.cols - 1
  let binds = ($layer | where sym == $key.sym)
  let face = if ($binds | length) > 1 { '💥' } else { $binds | get 0?.emoji | default '' }
  let label = if ($key.label | str length --grapheme-clusters) < $width { $" ($key.label)" } else { $key.label }
  let top = $label | str substring --grapheme-clusters 0..<$width | fill --width $width
  let bottom = if $face == '' { '' | fill --width $width } else { $" ($face)" + ('' | fill --width ($width - 3)) }
  let name = if $key.sym in $held { 'held' } else if $face != '' { 'bound' } else { 'free' }
  [(paint $name $top) (paint $name $bottom)]
}

def render-keyboard [keys: list, layer: list, mods: list] {
  let held = ($mods | each {|mod| $modifier_keys | get --optional $mod | default [] } | flatten)
  $keys | each {|row|
    let caps = ($row | each {|key|
      if $key.sym == '_' {
        let gap = ('' | fill --width $key.cols)
        [$gap $gap]
      } else {
        let cap = (keycap $key $layer $held)
        [$"($cap.0) " $"($cap.1) "]
      }
    })
    [($caps | each { get 0 } | str join) ($caps | each { get 1 } | str join)]
  } | flatten
}

def render-legend [layer: list, width: int] {
  let column = 38
  let count = ([1 ($width // $column)] | math max)
  let entries = (
    $layer | sort-by sym | each {|bind|
      let key = ($bind.key | str replace 'WheelScroll' 'Wheel')
      let text = $"($key | fill --width 6) ($bind.title)" | str substring --grapheme-clusters 0..<($column - 4)
      $"($bind.emoji) ($text | fill --width ($column - 3))"
    }
  )
  let height = (($entries | length) / $count | math ceil)
  0..<$height | each {|row|
    0..<$count | each {|col| $entries | get --optional ($col * $height + $row) | default '' } | str join
  }
}

def render [layers: list, index: int, keys: list] {
  let current = ($layers | get $index)
  let width = (term size).columns
  let tabs = (
    $layers | enumerate | each {|l|
      paint (if $l.index == $index { 'active' } else { 'tab' }) $" ($l.index + 1) ($l.item.name) "
    } | str join ' '
  )
  let needed = ($keys | get 0 | get cols | math sum)
  [
    $tabs
    (paint frame "Tab/←→ switch layer · 1-9 pick · q/Esc close")
    ''
    ...(render-keyboard $keys $current.binds $current.mods)
    ''
    ...(if $width < $needed { [(paint frame $"Widen the window to ($needed) columns to see the whole keyboard.") ''] } else { [] })
    ...(render-legend $current.binds $width)
  ] | str join "\n"
}

def main [config?: path] {
  let config = ($config | default ($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config" | path join niri config.kdl))
  let emoji = (open ($config | path dirname | path join keymap-emoji.nuon))
  let binds = (load-binds $config $emoji)
  let layers = (layer-names $binds | each {|name|
    let layer = ($binds | where layer == $name)
    { name: $name, mods: $layer.0.mods, binds: $layer }
  })
  let keys = (parse-rows)

  mut index = 0
  loop {
    print --no-newline $"(ansi clear_screen)(ansi home)(render $layers $index $keys)"
    let event = (input listen --types [key])
    let count = ($layers | length)
    match [$event.code ($event.modifiers | is-not-empty)] {
      ['q' _] | ['esc' _] => { break }
      ['backtab' _] | ['left' _] | ['tab' true] => { $index = ($index + $count - 1) mod $count }
      ['tab' _] | ['right' _] => { $index = ($index + 1) mod $count }
      [$digit _] if ($digit =~ '^[1-9]$') and ($digit | into int) <= $count => { $index = ($digit | into int) - 1 }
      _ => {}
    }
  }
}
