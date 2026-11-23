{ lib }:

# niri's binds as a honeycomb (lib/honeycomb/README.md): six cells of at most
# six members each. A member is one thing to remember; its chords are the
# plain key, the Shift form, and hidden twins on other devices. This file
# renders the `binds` block that config.kdl leaves out.
#
# The grammar is select, then act:
#   Mod + key          select: a column, a window, or something to open
#   Mod + Shift + key  act on the selection: carry it along, or the verb's
#                      other form
#   Mod + Ctrl + key   the same motion between monitors
#   Mod + Alt + key    the seven areas, by the direction each sits in
let
  honeycomb = import ../lib/honeycomb { inherit lib; };
  key = lib.mapAttrs (_: lib.toUpper) honeycomb.keys;

  # The home area is the centre; the other six sit around it (honeycomb's
  # areas). Each is a named workspace with a layout in session.nu.
  areas = lib.listToAttrs (map (area: lib.nameValuePair area.cell area.name) honeycomb.areas);

  bind = chord: title: action: {
    inherit chord title action;
    props = "";
  };
  # A twin of a titled bind on another device, left out of the overlay.
  twin = chord: action: bind chord null action;
  with' = props: b: b // { inherit props; };
  desk = command: ''spawn-sh "exec niri-desk ${command}"'';
  member = name: binds: { inherit name binds; };
  cell = name: cells: { inherit name cells; };

  # A motion: Mod selects, Shift carries the selection, Ctrl crosses monitors.
  motion =
    {
      name,
      letter,
      arrow,
      focus,
      move,
      monitor,
      side,
      select,
      carry,
      twins ? [ ],
    }:
    member name (
      [
        (bind "Mod+${letter}" select focus)
        (bind "Mod+Shift+${letter}" carry move)
        (bind "Mod+Ctrl+${letter}" "Select the monitor ${side}" "focus-monitor-${monitor}")
        (bind "Mod+Shift+Ctrl+${letter}" "Carry the column to the monitor ${side}"
          "move-column-to-monitor-${monitor}"
        )
        (twin "Mod+${arrow}" focus)
        (twin "Mod+Shift+${arrow}" move)
      ]
      ++ twins
    );

  window = cell "window" [
    (motion {
      name = "west";
      letter = key.w;
      arrow = "Left";
      focus = "focus-column-left";
      move = "move-column-left";
      monitor = "left";
      side = "to the west";
      select = "Select the column to the west";
      carry = "Carry the column west";
      twins = [
        (twin "MouseBack" "focus-column-left")
        (twin "Mod+WheelScrollLeft" "focus-column-left")
      ];
    })
    (motion {
      name = "east";
      letter = key.e;
      arrow = "Right";
      focus = "focus-column-right";
      move = "move-column-right";
      monitor = "right";
      side = "to the east";
      select = "Select the column to the east";
      carry = "Carry the column east";
      twins = [
        (twin "MouseForward" "focus-column-right")
        (twin "Mod+WheelScrollRight" "focus-column-right")
      ];
    })
    (motion {
      name = "down";
      letter = key.down;
      arrow = "Down";
      focus = "focus-window-or-workspace-down";
      move = "move-window-down-or-to-workspace-down";
      monitor = "down";
      side = "below";
      select = "Down the column, then the next workspace";
      carry = "Carry the window down, then to the next workspace";
    })
    (motion {
      name = "up";
      letter = key.up;
      arrow = "Up";
      focus = "focus-window-or-workspace-up";
      move = "move-window-up-or-to-workspace-up";
      monitor = "up";
      side = "above";
      select = "Up the column, then the previous workspace";
      carry = "Carry the window up, then to the previous workspace";
    })
    (member "back" [
      (bind "Mod+Tab" "Back to the previous window" "focus-window-previous")
    ])
    # Plain niri workspaces: the strip's next and previous, and each by its
    # position. The areas (Mod+Alt) reach the same workspaces by name.
    (member "workspace" (
      [
        (with' "repeat=false" (bind "Mod+O" "Overview: every workspace" "toggle-overview"))
        (bind "Mod+Page_Down" "Next workspace" "focus-workspace-down")
        (bind "Mod+Page_Up" "Previous workspace" "focus-workspace-up")
        (bind "Mod+Shift+Page_Down" "Carry the column to the next workspace"
          "move-column-to-workspace-down"
        )
        (bind "Mod+Shift+Page_Up" "Carry the column to the previous workspace"
          "move-column-to-workspace-up"
        )
        (with' "cooldown-ms=150" (twin "Mod+WheelScrollDown" "focus-workspace-down"))
        (with' "cooldown-ms=150" (twin "Mod+WheelScrollUp" "focus-workspace-up"))
      ]
      ++ lib.concatMap (
        n:
        let
          i = toString n;
        in
        [
          (bind "Mod+${i}" "Workspace ${i}" "focus-workspace ${i}")
          (bind "Mod+Shift+${i}" "Carry the column to workspace ${i}" "move-column-to-workspace ${i}")
        ]
      ) (lib.range 1 7)
    ))
  ];

  area =
    cell "area" (
      map (
        direction:
        let
          name = areas.${direction};
        in
        member name [
          (bind "Mod+Alt+${key.${direction}}" "Area: ${name}" (desk "area ${name}"))
          (bind "Mod+Shift+Alt+${key.${direction}}" "Carry the column to ${name}" (
            desk "area ${name} --carry"
          ))
        ]
      ) honeycomb.compass
    )
    // {
      # The depth keys: inward to the centre, outward to the list of sessions.
      depth = [
        (bind "Mod+Alt+${key.inward}" "Area: ${areas.centre}, the centre" (desk "area ${areas.centre}"))
        (bind "Mod+Shift+Alt+${key.inward}" "Carry the column to ${areas.centre}" (
          desk "area ${areas.centre} --carry"
        ))
        (bind "Mod+Alt+${key.outward}" "Sessions: areas and projects" (desk "overview"))
      ];
    };

  open = cell "open" [
    (member "terminal" [
      (bind "Mod+Return" "Terminal in this session" (desk "open"))
      (bind "Mod+Shift+Return" "Restore this session's layout" (desk "restore"))
    ])
    (member "launcher" [
      (bind "Mod+Space" "Launcher" ''spawn-sh "noctalia msg panel-toggle launcher"'')
    ])
    (member "browser" [
      (bind "Mod+B" "Browser" ''spawn "google-chrome" "--profile-directory=Default"'')
    ])
    (member "agents" [
      (bind "Mod+A" "Agents: bring the stack here, or the next agent" (desk "agents"))
      (bind "Mod+Shift+A" "Agents: float one over this workspace" (desk "peek agents"))
    ])
    (member "vcs" [
      (bind "Mod+G" "Version control: JJ and GitHub" (desk "vcs"))
    ])
    (member "notes" [
      (bind "Mod+N" "Notes: this area's hub" (desk "notes"))
      (bind "Mod+Shift+N" "Notes: capture into today" (desk "capture"))
    ])
  ];

  shape = cell "shape" [
    (member "width" [
      (bind "Mod+R" "Column width: half, two thirds, full" "switch-preset-column-width")
      (bind "Mod+Shift+R" "Window height: half or full" "switch-preset-window-height")
    ])
    (member "fill" [
      (bind "Mod+F" "Maximise the column" "maximize-column")
      (bind "Mod+Shift+F" "Fullscreen the window" "fullscreen-window")
    ])
    (member "float" [
      (bind "Mod+V" "Float or tile the window" "toggle-window-floating")
      (bind "Mod+Shift+V" "Select the floating or the tiled layer"
        "switch-focus-between-floating-and-tiling"
      )
    ])
    (member "tabs" [
      (bind "Mod+W" "Show the column as tabs" "toggle-column-tabbed-display")
      (bind "Mod+Shift+W" "Gather this window's alternatives into tabs" (desk "stack-choices"))
    ])
    (member "stack" [
      (bind "Mod+BracketLeft" "Pull the window into, or out of, the column to the west"
        "consume-or-expel-window-left"
      )
      (bind "Mod+BracketRight" "Pull the window into, or out of, the column to the east"
        "consume-or-expel-window-right"
      )
    ])
    (member "away" [
      (bind "Mod+Q" "Close the window" "close-window")
      (with' "repeat=false" (
        bind "Mod+X" "Minimise the window"
          ''spawn "noctalia" "msg" "plugin" "local/minimizer:actions" "all" "minimize"''
      ))
      (with' "repeat=false" (
        bind "Mod+Shift+X" "Minimised windows"
          ''spawn "noctalia" "msg" "plugin" "local/minimizer:actions" "all" "windows"''
      ))
    ])
  ];

  # Voice in, pictures out, and the labelled hardware keys.
  io = cell "io" [
    # dicta's tape recorder (modules/programs/desktop/dicta.nix). niri cannot bind Esc
    # to discard without taking Esc from every app, so discard is the Shift
    # form.
    (member "record" [
      (with' "repeat=false" (
        bind "Mod+M" "Recorder: start or stop a spoken note" ''spawn "dicta" "toggle"''
      ))
      (with' "repeat=false" (bind "Mod+Shift+M" "Recorder: discard this take" ''spawn "dicta" "cancel"''))
    ])
    # HEX reads the keyboard itself (modules/programs/desktop/hex.nix); this bind
    # starts its service on the first press and otherwise only keeps the
    # chord from the focused window.
    (member "dictate" [
      (with' "repeat=false" (
        bind "Mod+D" "Dictate: start or stop typing by voice"
          ''spawn-sh "systemctl --user is-active --quiet hex.service || exec hex start"''
      ))
      (with' "repeat=false" (
        bind "Mod+Shift+D" "Dictate: settings, shortcut, and model" ''spawn "hex" "app"''
      ))
      # The mouse's thumb button, which logid sends as F20 (hosts/asus). It
      # runs the transcript through HEX's Output steps, as the shortcut does.
      (with' "repeat=false" (twin "F20" ''spawn-sh "hex start >/dev/null && exec hex dictation toggle"''))
    ])
    (member "screenshot" [
      (bind "Print" "Screenshot: pick a region" "screenshot")
      (bind "Ctrl+Print" "Screenshot: the screen" "screenshot-screen")
      (bind "Alt+Print" "Screenshot: the window" "screenshot-window")
    ])
    (member "volume" (
      map (with' "allow-when-locked=true") [
        (twin "XF86AudioRaiseVolume" ''spawn-sh "noctalia msg volume-up"'')
        (twin "XF86AudioLowerVolume" ''spawn-sh "noctalia msg volume-down"'')
        (twin "XF86AudioMute" ''spawn-sh "noctalia msg volume-mute"'')
      ]
    ))
    (member "brightness" (
      map (with' "allow-when-locked=true") [
        (twin "XF86MonBrightnessUp" ''spawn-sh "noctalia msg brightness-up"'')
        (twin "XF86MonBrightnessDown" ''spawn-sh "noctalia msg brightness-down"'')
      ]
    ))
  ];

  system = cell "system" [
    (member "panel" [
      (bind "Mod+S" "Control centre" ''spawn-sh "noctalia msg panel-toggle control-center"'')
      (bind "Mod+Shift+S" "Shell settings" ''spawn-sh "noctalia msg settings-toggle"'')
    ])
    (member "keys" [
      (bind "Mod+Slash" "Keys: this tree as a keyboard" (desk "keymap"))
      (bind "Mod+Shift+Slash" "Keys: niri's own list" "show-hotkey-overlay")
    ])
    # An application may ask niri to stop reading shortcuts; this one always
    # gets through, so nothing can hold the session.
    (member "guard" [
      (with' "allow-inhibiting=false" (
        bind "Mod+Escape" "Pass every key to the window, or stop" "toggle-keyboard-shortcuts-inhibit"
      ))
      (bind "Mod+Shift+Escape" "Lock the screen" ''spawn "swaylock"'')
    ])
    (member "screens" [
      (bind "Mod+Shift+P" "Turn the screens off" "power-off-monitors")
    ])
    (member "quit" [
      (bind "Mod+Shift+E" "Quit niri" "quit")
    ])
  ];

  tree = cell "niri" [
    window
    area
    open
    shape
    io
    system
  ];

  bindsOf = c: lib.concatMap (m: m.binds) c.cells ++ (c.depth or [ ]);
  binds = lib.concatMap bindsOf tree.cells;
  chords = map (b: b.chord) binds;

  render =
    b:
    let
      title =
        if b.title == null then "hotkey-overlay-title=null" else ''hotkey-overlay-title="${b.title}"'';
      props = lib.concatStringsSep " " (
        lib.filter (p: p != "") [
          b.props
          title
        ]
      );
    in
    "    ${b.chord} ${props} { ${b.action}; }";

  renderCell = c: "    // ${c.name}\n" + lib.concatMapStringsSep "\n" render (bindsOf c);

  kdl = ''
    // Generated from niri/binds.nix; edit the tree there.
    binds {
    ${lib.concatMapStringsSep "\n\n" renderCell tree.cells}
    }
  '';
in
assert lib.assertMsg (honeycomb.crowded tree == [ ])
  "niri/binds.nix: cells over six: ${lib.generators.toPretty { } (honeycomb.crowded tree)}";
assert lib.assertMsg (chords == lib.unique chords)
  "niri/binds.nix: a chord is bound twice: ${
    toString (lib.filter (chord: lib.count (c: c == chord) chords > 1) (lib.unique chords))
  }";
{
  inherit
    areas
    kdl
    tree
    ;
  # The key that points in each direction, with centre on the inward key.
  keys =
    removeAttrs key [
      "down"
      "up"
      "inward"
      "outward"
    ]
    // {
      centre = key.inward;
    };
  # The key that leads outward, to the list of sessions, and the two that
  # step down and up a column's windows.
  out = key.outward;
  inherit (key) down up;
  # The chords on each navigation seat, for the input stack
  # (modules/programs/desktop/input-stack.nix): Mod moves among windows on
  # four of them, and Mod+Alt among areas on the six directions, in and out.
  navigation = lib.mapAttrs (
    seat: letter:
    lib.optional (lib.elem seat [
      "w"
      "e"
      "down"
      "up"
    ]) "Mod+${letter}"
    ++ lib.optional (
      !lib.elem seat [
        "down"
        "up"
      ]
    ) "Mod+Alt+${letter}"
  ) key;
  # What niri loads: the hand-written settings, then the generated binds.
  config = builtins.readFile ./config.kdl + "\n" + kdl;
}
