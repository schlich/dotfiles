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
pane and inline `sudo` approval, so it can run `ci land`'s local clearance
build and offer `nixos-rebuild switch`.

It ends when the laptop sleeps or shuts down, and long builds load the
laptop. Concurrent tasks need their own workspaces (`ci start`).

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
`ci land` clearance runs without the laptop.

It only has what that host installs: its Claude configuration, plugins and
MCP servers must be deployed there declaratively, and the homelab still has
orphaned Home Manager links from August. It needs its own checkout, Tangled
credentials and JJ workspace. It can build the `asus` closure but must not
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

- It works from GitHub. `origin` mirrors only `main` and topics live on
  Tangled; a repository can be bundled and uploaded instead, but results
  cannot be pushed back to a non-GitHub remote. The session produces a Git
  branch, not a JJ topic, and cannot run `ci dispatch` or `ci land`.
- It lacks the Home Manager MCP servers, hooks and Nushell unless a setup
  script installs them, and network access is restricted.
- It cannot activate anything on a real host.

## Choosing

| Need                                               | Use              |
| -------------------------------------------------- | ---------------- |
| Configuration work, landing, activation            | Local            |
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
maps only the user's UID, so `/nix/store` appears owned by `nobody`. SSH
then rejects the Home Manager-linked config:

```text
Bad owner or permissions on /home/schlich/.ssh/config
```

That blocks Tangled fetches and pushes, so `ci new`, `ci dispatch` and
`ci land` fail inside it. Start a topic offline with
`jj new main@tangled -m MESSAGE` and run the networked `ci` steps from an
unsandboxed shell.
