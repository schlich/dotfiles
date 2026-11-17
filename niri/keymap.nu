# An emoji keyboard of the niri binds (Mod+Slash, `niri-desk keymap`).
#
# Reads the `binds { }` block of config.kdl, groups binds into layers by their
# modifiers, and draws one layer per `tui` page as an ANSI keyboard: the main
# block, the navigation cluster, and the numpad that holds the Johnny Decimal
# grid. Each bound key shows the emoji of its action from keymap-emoji.nuon,
# and a legend below names every bind of the layer, including mouse and media
# binds that have no keycap. A key bound twice in one layer shows 💥.
#
# A digit or [ ] picks a layer, the arrows move through its legend, / filters
# every layer's legend by title, and q or Esc closes (Esc first leaves the
# filter).
#
# `niri-keymap hints` is the always-on counterpart: it names the focus context
# (the bar's mode) and the few binds that matter there, for the status bar.

const emoji_file = path self keymap-emoji.nuon

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

# `spawn-sh "exec niri-desk grid left";` reads `run session grid left`.
def normalise [action: string] {
  $action
  | str trim
  | str trim --right --char ';'
  | str replace --all '\"' '"'
  | str replace --all '"' ''
  | str replace --regex 'exec niri-desk' 'session'
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

def keymap-layers [config: path] {
  let binds = (load-binds $config (open $emoji_file))
  layer-names $binds | each {|name|
    let layer = ($binds | where layer == $name)
    { name: $name, mods: $layer.0.mods, binds: $layer }
  }
}

# The overlay as a `tui` value: a page per layer, so tui's own 1-9 and [ ]
# switch layers (a hook cannot move a highlight or change the page). The
# keyboard is a preview of the legend's highlighted bind, titled with its
# chord and painted to the pane's $env.TUI_WIDTH. The search box sits in the
# chrome, so one query filters the legend of every page.
#
# tui 0.116 appends a generic tail to the status bar; its `focus:` field is
# the only mode indicator a hook-free TUI can show, so the legends are named
# normal-N and the search box filter, and `page:` names the layer.
def keymap-tui [layers: list, keys: list] {
  let needed = ($keys | each { get cols | math sum } | math max)
  $layers | enumerate | reduce --fold (
    tui label --title "niri keymap"
    | tui search --id filter --bind / --columns [title] --placeholder "/ filter binds by title"
  ) {|layer, ui|
    let number = $layer.index + 1
    let current = $layer.item
    let legend = $"normal-($number)"
    let rows = (
      $current.binds | sort-by sym | each {|bind|
        {
          name: ($bind.mods | append $bind.key | str join '+')
          key: $"($bind.emoji) ($bind.key | str replace 'WheelScroll' 'Wheel')"
          title: $bind.title
        }
      }
    )
    $ui | tui tab $"($number) ($current.name)" [
      (
        tui split --vertical --sizes [15 1fr] [
          (
            tui preview --from $legend {|bind|
              let width = ($env.TUI_WIDTH? | default $needed)
              [
                (if $width < $needed { paint frame $"Widen the window to ($needed) columns to see the whole keyboard." } else { '' })
                ...(render-keyboard $keys $current.binds $current.mods)
              ] | str join "\n"
            }
          )
          ($rows | tui table --id $legend --columns [key title])
        ]
      )
    ]
  }
  | tui label --status "1-9 [ ] layer · ↑↓ bind · / filter, Esc back · q/Esc close"
}

# The file niri loads: $NIRI_CONFIG, else the user's config.kdl if there is
# one, else the system's /etc/niri/config.kdl.
def default-config [] {
  let user = ($env.XDG_CONFIG_HOME? | default $"($env.HOME)/.config" | path join niri config.kdl)
  $env.NIRI_CONFIG? | default (if ($user | path exists) { $user } else { '/etc/niri/config.kdl' })
}

# The keys that matter in each focus context, with short labels for the bar.
# A hint whose key is no longer bound in config.kdl drops out, and a hint
# without a label falls back to the bind's hotkey-overlay-title. Overview keys
# are niri's own, and Alt+Tab may live in the recent-windows block instead of
# binds, so those always show.
const hint_sets = {
  normal: [[key label]; [Mod+1…9 area] [Mod+Tab back] [Alt+Tab recent] [Mod+A agents] [Mod+G vcs] [Mod+O overview] [Mod+Alt+M minimize] [Mod+Ctrl+M minimized] [Mod+Slash keymap]]
  empty: [[key label]; [Mod+Return terminal] [Mod+Shift+Return "restore layout"] [Mod+0 launcher] [Mod+A agents] [Mod+Ctrl+M minimized]]
  single: [[key label]; [Mod+R width] [Mod+F maximise] [Mod+Return terminal] [Mod+A agents] [Mod+Tab back] [Mod+Alt+M minimize] [Mod+Ctrl+M minimized]]
  stack: [[key label]; [Mod+J next] [Mod+K previous] [Mod+W tabs] [Mod+Period expel] [Mod+Shift+R height] [Mod+Alt+M minimize] [Mod+Ctrl+M minimized]]
  floating: [[key label]; [Mod+V tile] [Mod+Shift+V "to tiled"] [Mod+Q close] [Mod+Alt+M minimize] [Mod+Ctrl+M minimized]]
  overview: [[key label]; [←↓↑→ move] [Return pick] [Escape close]]
}
const always_shown = [Mod+1…9 Alt+Tab ←↓↑→ Return Escape]

def niri-json [query: string] {
  ^niri msg --json $query | from json
}

# normal (the base mode's shared name), empty, single, stack, floating or
# overview, from niri's focus.
def focus-context [] {
  if (niri-json overview-state).is_open { return 'overview' }
  let focused = (niri-json focused-window)
  if $focused == null { return 'empty' }
  if $focused.is_floating { return 'floating' }
  let tiled = (niri-json windows | where workspace_id == $focused.workspace_id and not $it.is_floating)
  let column = $focused.layout.pos_in_scrolling_layout.0
  if ($tiled | where layout.pos_in_scrolling_layout.0 == $column | length) > 1 { return 'stack' }
  if ($tiled | get layout.pos_in_scrolling_layout | each { get 0 } | uniq | length) == 1 { return 'single' }
  'normal'
}

def hint-status [binds: list, mode: string] {
  let titles = ($binds | each {|b| { key: ($b.mods | append $b.key | str join '+'), title: $b.title } })
  let hints = (
    $hint_sets | get $mode
    | where {|h| $h.key in $always_shown or $h.key in $titles.key }
    | each {|h| $h | update label { default ($titles | where key == $h.key | get 0?.title) } }
  )
  { mode: $mode, hints: $hints }
}

# The bar's hint line (Noctalia plugin niri-hints): follows niri's event
# stream and writes the focus context and its keys to
# $XDG_RUNTIME_DIR/niri-hints/status.json whenever they change. --once
# prints the current status instead.
def "main hints" [--once, config?: path] {
  let config = ($config | default (default-config))
  let binds = (load-binds $config [])
  if $once { return (hint-status $binds (focus-context)) }
  let dir = ($env.XDG_RUNTIME_DIR? | default /tmp | path join niri-hints)
  mkdir $dir
  let file = ($dir | path join status.json)
  ^niri msg --json event-stream | lines | reduce --fold '' {|_, last|
    let status = (hint-status $binds (focus-context) | to json --raw)
    if $status != $last { $status | save --force $file }
    $status
  }
}

def main [config?: path] {
  let config = ($config | default (default-config))
  keymap-tui (keymap-layers $config) (parse-rows) | tui run | ignore
}
