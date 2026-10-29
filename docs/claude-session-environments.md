# Where to run Claude Code sessions

Claude Code can run a session in four places. They differ in where the
process, the files and the tools live, and that decides what the session can
do in this repository.

| Environment    | Runs on        | Files and tools         | Outlives sleep |
| -------------- | -------------- | ----------------------- | -------------- |
| Local          | this machine   | this checkout, HM tools | no             |
| Remote Control | this machine   | same as local           | no             |
| SSH            | e.g. `homelab` | that host's checkout    | yes            |
| Cloud          | Anthropic VM   | a fresh clone           | yes            |

Remote Control is steered from claude.ai or the mobile app; "HM tools" are
the MCP servers, hooks and skills Home Manager installs.

## Local

The default for this repository. The session has every MCP server, hook and
skill that `modules/tooling/ai/` installs, the Nix dev shell, the browser
pane, the luvus server and inline approval for privileged commands, so it
can run the luvus gate, `luvus-deliver` and `system-switch`.

It ends when the laptop sleeps or shuts down, and long builds load the
laptop. Concurrent tasks need their own worktrees (`luvus task start`).

## Remote Control

The same session as local, steered from another device. Everything stays on
this machine; only the conversation passes through Anthropic. Use it to
approve prompts or redirect work while away from the desk.

The laptop must stay awake and online, and the phone client lacks the
browser pane, terminal panel and diff views. Do not edit the same working
copy from the laptop while the agent is working in it.

## SSH

A session on another host, with that host's files and tools. The desktop
app (beta) installs its own engine under `~/.claude/remote/` on first
connection; the host needs an SSH server with SFTP, a POSIX shell, `git` and
about 700 MB of disk. An always-on
host such as `homelab` can carry long sessions and heavy `nix build` or
gate runs without the laptop.

It only has what that host installs: its Claude configuration, plugins and
MCP servers must be deployed there declaratively, and the homelab still has
orphaned Home Manager links from August. It needs its own checkout and
GitHub credentials, and luvus runs on asus, so a branch made there is merged
and delivered from asus. It can build the `asus` closure but must not
activate it; switching the laptop remains a local, manual step. Local-only
features such as the browser pane and Claude in Chrome do not apply.

## Cloud

A sandbox VM that clones the repository and keeps working with the laptop
closed. It suits throwaway or parallel work on projects hosted on GitHub.
`claude --cloud` starts a new cloud session from the current repository,
uploading uncommitted changes to tracked files; `claude --teleport` pulls a
cloud session back into the terminal. An existing local session cannot be
pushed to the cloud.

It is the weakest fit here:

- It works from GitHub and produces a Git branch, but it cannot reach this
  machine's luvus server, which merges tasks into `luvus/integration`, so
  `AGENTS.md` rules it out for this repository.
- It lacks the Home Manager MCP servers, hooks and Nushell unless a setup
  script installs them, and network access is restricted.
- It cannot activate anything on a real host.

## Choosing

| Need                                               | Use              |
| -------------------------------------------------- | ---------------- |
| Configuration work, delivery, activation           | Local            |
| The same while away from the desk                  | Remote Control   |
| Long builds or always-on agents on this stack      | SSH to `homelab` |
| Throwaway parallel work on a GitHub-hosted project | Cloud            |

Agents watch for the symptoms of a poor fit, such as sandbox SSH failures,
missing tools, long builds on the laptop or interrupted sessions, and
suggest a better environment once per cause. The rule lives in the
"Session environment" section of
`modules/tooling/ai/global-agent-instructions.md`.

## Sandboxed local sessions

The desktop app can run a local session's tools in a user namespace that
maps only the user's UID, so `/nix/store` appears owned by `nobody`; it also
hides host `/etc` and sets no-new-privileges. SSH used to reject the Home
Manager-linked config there:

```text
Bad owner or permissions on /home/schlich/.ssh/config
```

ssh now reads its client configuration from the store through `-F`
(`modules/programs/ssh-client.nix`), which skips that check, and Home
Manager no longer links `~/.ssh/config`. `sudo` cannot gain privileges in
the sandbox, so privileged commands run through `run0`, which polkit
approves in a dialog; `system-switch` needs neither.
