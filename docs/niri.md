# Using niri

How the workstation desktop is meant to be driven. `niri/config.kdl` and
`niri/session.nu` enforce these rules; the rules explain why the binds are
shaped the way they are. The panel is a laptop screen that fits two columns.
Which keys Niri may claim, and which it leaves to the terminal and editor, is
in [input.md](input.md).

## Doctrine

1. **A workspace is a task.** Workspaces 1–9 are pinned places (Work,
   Research, XR, Nix, AI, Shell, Career, Personal, Inbox), laid out like the
   numpad (7 8 9 / 4 5 6 / 1 2 3). Projects opened from the
   session launcher take the workspaces after them. Apps open on the
   workspace that has focus, so go to the area first, then open.
1. **A column is a role. A tab is an alternative.** Windows you use together
   sit side by side. Windows that do the same job share one tabbed column:
   the coding agents (Mod+A), JJ and GitHub (Mod+G), or any app's own windows
   (Mod+Alt+W).
1. **Two columns fit the screen.** Widths are ½, ⅔ or full (Mod+R). Focus
   scrolls only when the next column would not fit, and a lone window
   centres itself.
1. **Jump; don't scroll.**
   - Mod+digit goes to an area; pressing it again goes back.
   - Mod+Tab returns to the previous window, on any workspace.
   - Alt+Tab is the one window switcher, most recent first.
   - Mod+O, the top-left corner, or a three-finger swipe up shows the
     overview.
1. **The usable keys are on screen.** Mod+Shift+/ lists one key per action.
   Mod+/ draws every bind as an emoji keyboard.

## Daily routine

1. **Mod+digit** goes to the area.
1. **Mod+Shift+Return** rebuilds its session layout if it is empty.
1. **Mod+A** brings the agents beside the work, or **Mod+Shift+A** floats
   one over it.
1. **Mod+R** sizes the focused column, and **Mod+F** gives it the whole
   panel.
1. **Mod+Tab** goes back to wherever you just were.

## Canonical keys

| Group    | Key                 | Action                                      |
| -------- | ------------------- | ------------------------------------------- |
| Jump     | Mod+1…9             | Area (again: back)                          |
|          | Mod+0               | Session launcher                            |
|          | Mod+Tab             | Previous window                             |
|          | Alt+Tab / Alt+\`    | Recent windows / recent windows of this app |
|          | Mod+U / Mod+I       | Next / previous session with windows        |
|          | Mod+Alt+H/J/K/L     | Neighbouring area on the grid               |
|          | Mod+O               | Overview                                    |
| Arrange  | Mod+H/J/K/L         | Focus column / window                       |
|          | Mod+Shift+H/J/K/L   | Move column / window                        |
|          | Mod+Shift+1…9       | Send column to area                         |
|          | Mod+[ / Mod+]       | Pull window into, or out of, a column       |
|          | Mod+V / Mod+Shift+V | Float / switch between floating and tiled   |
| Size     | Mod+R               | ½ → ⅔ → full                                |
|          | Mod+Shift+R         | Window height ½ ↔ full in a stack          |
|          | Mod+F / Mod+Ctrl+F  | Maximise / fill the remaining width         |
|          | Mod+C               | Centre column                               |
| Sessions | Mod+Return          | Terminal in this session                    |
|          | Mod+Shift+Return    | Restore session layout                      |
|          | Mod+N / Mod+Shift+N | Area notes / capture a note                 |
| Stacks   | Mod+A / Mod+Shift+A | Agents stack / peek at an agent             |
|          | Mod+G               | VCS stack                                   |
|          | Mod+W               | Show column as tabs                         |
|          | Mod+Alt+W           | Gather this window's alternatives into tabs |
|          | Mod+Alt+1…4         | Tab 1–4 of this column                      |

The arrow, Page and wheel versions of these keys still work. They are hidden
from the overlay so that it lists one key per action.

## Habits to unlearn

- **Scrolling the strip to find a window.** Use Mod+Tab, Alt+Tab or Mod+O
  instead.
- **Opening an app and then moving it.** Go to the area first.
- **Thin side-by-side columns.** If a third window needs to be visible, it is
  probably an alternative: tab it with Mod+\[ or Mod+Alt+W.
- **Mod+Tab for the last workspace.** Press that area's digit again instead.
