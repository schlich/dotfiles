# Using niri

How the workstation desktop is meant to be driven. `niri/binds.nix` holds the
binds as a tree, `niri/config.kdl` the other settings, and `niri/session.nu`
the areas and sessions. The panel is a laptop screen that fits two columns.
Which keys Niri may claim, and which it leaves to the terminal and editor, is
in [input.md](input.md). The limit of six that shapes all of this is in
[lib/honeycomb/README.md](../../lib/honeycomb/README.md).

## Doctrine

1. **Select, then act.** Mod plus a key selects something. Adding Shift acts
   on the selection: it carries the column or window along the same motion,
   or gives the verb's other form. Adding Ctrl makes the motion cross
   monitors.
1. **Seven areas, one centre.** `home` sits in the middle and `work`,
   `research`, `nix`, `ai`, `xr` and `life` sit around it. Mod+Alt plus a
   direction key selects the area in that direction, from anywhere, so each
   area has one key for good. Projects opened from the session launcher take
   workspaces of their own.
1. **A column is a role. A tab is an alternative.** Windows you use together
   sit side by side. Windows that do the same job share one tabbed column:
   the coding agents (Mod+A), JJ and GitHub (Mod+G), or any app's own windows
   (Mod+Shift+W).
1. **Two columns fit the screen.** Widths are ½, ⅔ or full (Mod+R). Focus
   scrolls only when the next column would not fit.
1. **Six at a time.** The binds are six cells of at most six members.
1. **A hint sits where its key points.** The bars show only navigation: Y
   and U in the top corners, H and L on the side bars, N and M in the bottom
   corners, J at the bottom centre with the mode, and K at the top centre.
   Each names the area its key selects, and the focused area's hint is lit.
   Mod+/ draws every other bind as an emoji keyboard.

## The areas

```text
        Y xr        U life
   H ai       I home       L work
        N nix       M research
```

Mod+Alt+O, outward, opens the session launcher: this map with the areas that
are open, and the projects.

## Keys

| Cell   | Member     | Key                                 | With Shift                    |
| ------ | ---------- | ----------------------------------- | ----------------------------- |
| Window | West, east | Mod+H, Mod+L                        | Carry the column              |
|        | In, out    | Mod+J, Mod+K: next, previous window | Carry the window              |
|        | Back       | Mod+Tab                             |                               |
|        | Workspace  | Mod+O overview                      |                               |
|        |            | Mod+PgDn, Mod+PgUp: next, previous  | Carry the column              |
|        |            | Mod+1 … Mod+7: by position          | Carry the column              |
| Area   | Six areas  | Mod+Alt+Y U H L N M                 | Carry the column there        |
|        | Centre     | Mod+Alt+I, inward                   | Carry the column there        |
|        | Sessions   | Mod+Alt+O, outward                  |                               |
| Open   | Terminal   | Mod+Return                          | Restore the session's layout  |
|        | Launcher   | Mod+Space                           |                               |
|        | Browser    | Mod+B                               |                               |
|        | Agents     | Mod+A                               | Float one over this workspace |
|        | VCS        | Mod+G                               |                               |
|        | Notes      | Mod+N                               | Capture into today            |
| Shape  | Width      | Mod+R: ½ → ⅔ → full                 | Window height                 |
|        | Fill       | Mod+F                               | Fullscreen                    |
|        | Float      | Mod+V                               | Select floating or tiled      |
|        | Tabs       | Mod+W                               | Gather alternatives into tabs |
|        | Stack      | Mod+\[, Mod+\]: into, out of column |                               |
|        | Away       | Mod+Q close, Mod+X minimise         | Mod+Shift+X: minimised        |
| IO     | Record     | Mod+M                               | Discard the take              |
|        | Dictate    | Mod+D                               | Settings                      |
|        | Screenshot | Print, Ctrl+Print, Alt+Print        |                               |
|        | Volume     | The volume keys                     |                               |
|        | Brightness | The brightness keys                 |                               |
| System | Panel      | Mod+S                               | Shell settings                |
|        | Keys       | Mod+/                               | niri's own list               |
|        | Guard      | Mod+Escape: pass keys through       | Lock the screen               |
|        | Screens    |                                     | Mod+Shift+P: screens off      |
|        | Quit       |                                     | Mod+Shift+E                   |

Past a column's first or last window, Mod+J and Mod+K step on to the
previous or next workspace, and Mod+Shift+J and Mod+Shift+K carry the window
there. Mod+Ctrl+H/J/K/L selects a monitor, and adding Shift carries the column to
it. Alt+Tab and Alt+\` are niri's window switcher. The arrow keys, the mouse
thumb buttons and Mod plus the wheel repeat the window motions; they are
hidden from the overlay so that it lists one key per action.

## Daily routine

1. **Mod+Alt plus a direction** selects the area.
1. **Mod+Shift+Return** rebuilds its session layout if it is empty.
1. **Mod+A** brings the agents beside the work, or **Mod+Shift+A** floats
   one over it.
1. **Mod+R** sizes the focused column, and **Mod+F** gives it the whole
   panel.
1. **Mod+Tab** goes back to wherever you just were.

## What went away

The keypad grid, Mod+U and Mod+I, Mod+Home and Mod+End, Mod+C, the comma
and period, the fine width and height steps, and the numbered tabs. Each was
a second way to do something a direction key or a preset already does. The
digits and Page keys came back (2026-11-23) as plain niri workspace
navigation beside the areas.
