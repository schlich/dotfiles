# Agent monitor

The Fieldnotes dashboard lives in its own repository,
[schlich/fieldnotes](https://github.com/schlich/fieldnotes), and comes in
through the `fieldnotes` flake input with the tools its panels read from
(`modules/tooling/ai/fieldnotes-package.nix`). Homelab opens it full screen
when its graphical session starts; `fieldnotes` runs it anywhere else,
including over SSH.

These scripts feed its background-task panel:

- `record-background-task.nu`, a Claude Code PostToolUse hook, records each
  background Bash task and each Monitor as
  `$XDG_STATE_HOME/fieldnotes/agent-tasks/<id>.json`.
- `push-background-tasks.nu`, run by the `agent-tasks-push` timer, marks
  finished tasks, drops those finished more than 15 minutes ago, and copies
  the host's list to homelab as `<host>.json`.
