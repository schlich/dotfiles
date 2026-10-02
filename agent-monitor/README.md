# Agent monitor

Homelab opens this Textual dashboard in an Alacritty window when its graphical
session starts. Run `agent-monitor` in a terminal or an SSH session to open it
manually. Quitting closes the dashboard; it does not immediately restart.

The dashboard shows provider usage and reset windows, GitHub Actions results
(including failure streaks and retired workflows), published Tangled topics
waiting to land, and Claude background tasks from other hosts. All rows remain
available by scrolling, including in a narrow terminal.

The persistent hint line lists every keyboard shortcut. The single mode is
**Normal**: arrow keys scroll, Page Up/Down move a page, Home/End jump to the
top/bottom, R refreshes, and Q or Ctrl+C quits. Mouse scrolling also works.

Remote sources refresh independently every 30 seconds. Background tasks and
relative timestamps update every second. A failed refresh displays its error
and retains the last successful data with its age. Slow requests leave the
interface responsive, and refresh requests do not overlap for the same source.

The Nix package supplies Textual, `gh`, and `ai-usagebar`. Provider credentials
and GitHub authentication belong to the account running the dashboard.

Optional environment variables:

| Variable                      | Default                                 | Purpose                   |
| ----------------------------- | --------------------------------------- | ------------------------- |
| `FIELDNOTES_CI_REPO`          | `schlich/dotfiles`                      | GitHub Actions repository |
| `FIELDNOTES_TANGLED_KNOT`     | `https://knot1.tangled.sh`              | Tangled knot endpoint     |
| `FIELDNOTES_TANGLED_REPO_DID` | Repository DID in `tui.py`              | Tangled repository        |
| `FIELDNOTES_TASKS_DIR`        | `~/.local/state/fieldnotes/agent-tasks` | Host task snapshots       |
