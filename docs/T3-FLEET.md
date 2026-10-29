# T3 Code fleet

Coding agents run on the NixOS hosts; the desktop app, the Android app and
outside agents drive them. T3 Code does the orchestration: one server per
host (an _environment_), linked environments for cross-machine delegation,
and an MCP endpoint per environment. This repository only installs, starts
and publishes it.

## Architecture

| Host      | Role                                    | T3 Code                                                    |
| --------- | --------------------------------------- | ---------------------------------------------------------- |
| `homelab` | Always-on execution host, from boot     | `t3code-server` user unit on `~/.t3`; the user lingers     |
| `asus`    | Execution host while logged in, desktop | `t3code-server` user unit on `~/.t3`; the app is a client  |
| Phone     | Control surface                         | T3 Code for Android, over the tailnet; push via T3 Connect |

Each server listens on `127.0.0.1:3773` only. A root unit,
`t3code-tailscale-serve`, publishes it with Tailscale Serve at
`https://HOST.tail338351.ts.net:3773/`, which only tailnet devices reach;
nothing listens on a LAN or public address, and Funnel is not used. Every
client still pairs with the server before it can do anything.

```text
 phone ──┐   tailnet HTTPS (Serve)      ┌─ asus:    t3code-server ─┐
 desktop ┼──────────────────────────────┤                          ├─ linked
 agents ─┘   loopback on the same host  └─ homelab: t3code-server ─┘  environments
                                             │
             T3 Connect, publish-only ───────┘ push notifications, no tunnel
```

Where it is declared:

| Piece                                  | File                                                                        |
| -------------------------------------- | --------------------------------------------------------------------------- |
| Which hosts run a server               | `den/inventory.nix` (`services.t3code`)                                     |
| Package (0.1.4, pinned)                | `flake.nix` input `nixpkgs-t3code`, `modules/tooling/ai/t3code-package.nix` |
| User unit, MCP entries, desktop client | `modules/tooling/ai/t3code-server.nix`                                      |
| Linger and Tailscale Serve             | `modules/nixos/t3code.nix`                                                  |
| Den wiring and fleet URLs              | `den/aspects/t3code.nix`                                                    |
| Nushell helpers (`t3f`)                | `modules/tooling/ai/scripts/t3f.nu`                                         |

### Why these choices

- **Version.** Linked environments and `delegate_task` first shipped in
  v0.1.4 (2026-10-29). The locked nixpkgs has 0.0.45, so `t3code` comes from
  the nixpkgs commit that packaged 0.1.4 (NixOS/nixpkgs#580444), built from
  source; nothing else is taken from that input. `nixpkgs-watch` reports when
  the main nixpkgs input catches up.
- **Declarative unit, not `t3 service install`.** The upstream installer
  writes a unit naming one store path and updates itself; here Nix owns the
  version. The unit follows upstream's (`KillMode=mixed`, `OOMPolicy`,
  weights, start limits). Agents run in their own systemd scopes
  (`app-t3code-agents-*.slice`), and a restarted server recovers their
  runs: in the smoke test a task that was running during a restart finished
  afterwards, with its history.
- **Linger only where nothing logs in.** homelab's user lingers, so its
  server runs from boot. asus is `portable`: lingering would start all of its
  user services at boot, before a login unlocks the keyring that the Codex
  and OpenCode wrappers read, so there the server runs while you are logged
  in.
- **One server per `~/.t3`.** T3 holds an exclusive lock on its state
  directory. On asus the desktop app therefore runs without a local
  environment: its `t3code-desktop` launcher turns that off before every
  start. A server that finds the lock taken exits 78 and is not restarted.
- **Tailscale Serve run by root**, not `t3 serve --tailscale-serve`, which
  needs Tailscale operator rights for the user, and so for every agent the
  user runs.
- **T3 Connect publish-only.** It carries push notifications and Live
  Activities without the managed Cloudflare tunnel; connections stay on the
  tailnet.
- **Pairing tokens stay out of the journal.** `t3 serve` prints a one-time
  admin pairing token, its link and a QR code at every start, on stdout with
  the log. The unit's wrapper drops those lines and keeps the rest
  (`t3f logs`).
- **Explicit PATH.** T3 reads PATH from a non-interactive login shell, and
  `nu -l -c` exits 1 without a terminal here (Home Manager's gpg-agent
  integration runs `$env.GPG_TTY = (tty)`), so the unit's own PATH, with the
  profile, is what finds `claude`, `codex` and `opencode`.

## One-time setup

The configuration activates like any other: after delivery,
`system-switch --with-home` on asus; homelab stages the system on its own,
and its home needs `home-activate` there.

### On each execution host

1. Check the server: `t3f status` (or
   `systemctl --user status t3code-server`). A first start on an old
   `~/.t3` migrates the database in place; the pre-0.1.0 `state.sqlite` is
   kept for rollback.
1. Sign in the providers the host should offer, on that host:
   `claude auth login`, `codex login --device-auth`, `opencode auth login`.
   Logins persist in each CLI's own store, outside Nix.
1. Turn on **Settings → Labs → Linked environments** for the host (in any
   client connected to it).
1. Push notifications: `t3 connect link --publish-only --headless`, sign in
   with the T3 Connect account the phone uses, then
   `systemctl --user restart t3code-server`. A free account links three
   machines.

### Desktop (asus)

Quit T3 Code before the first activation. Then pair the app with the local
server once: run `t3 pair`, open the `t3code://pair` link it prints, and
confirm. Add homelab the same way with a link from `t3f pair` on homelab, or
use **Settings → Environments → Add environment** with its pairing URL.

### Android

1. Keep the phone on the tailnet (Tailscale app, always-on VPN), and install
   T3 Code from Google Play.
1. On each host, `t3f pair --label pixel --ttl 10m` prints a QR code for
   `https://HOST.tail338351.ts.net:3773/pair#token=…`; scan it under
   **Settings → Environments → Add environment**. The link is a password.
1. Sign in to the same T3 Connect account, link the environments and turn on
   **Settings → Notifications → Device Notifications** (and **Ongoing Agent
   Activity**). Tapping a notification opens its thread; approvals and
   questions are answered there.

### Link the machines

Link each host to the others so agents can delegate across them. From
asus: `t3f link homelab`, which asks homelab for a ten-minute pairing code
over ssh, or `t3f link homelab --pairing-code CODE` with a code from
homelab's **Settings → Sharing & access**. Link homelab to asus the same way
for the other direction. `--access` caps what the linked agents may do
there; the default, `approval-required`, makes their file changes and
commands wait for an approval you give from any client. Links last 30 days;
link again to renew. `t3 environment list` shows them.

### Outside agents (MCP)

Each environment serves MCP at `/mcp`. With linked environments, one
environment's MCP reaches the others too (`t3_environment_links`, then an
`environmentId` on any tool; `delegate_task` takes `target.environmentId`).
Claude Code and Codex list the local server as `t3`
(`http://127.0.0.1:3773/mcp`); sign each in once:

- Claude Code: `/mcp`, choose `plugin:hm:t3`, **Authenticate**.
- Codex: `codex mcp login t3`.

The sign-in page asks for a pairing code (`t3 auth pairing create --scope orchestration:read --scope orchestration:operate --ttl 10m`) and an access
level. Choose **Supervised** unless the agent needs more: T3 caps the threads
an outside agent starts at that level, and T3-run sessions see this entry
too. Revoke an agent under **Settings → Sharing & access**; sign-ins last 30
days. From another host, an agent can sign in to
`https://HOST.tail338351.ts.net:3773/mcp` the same way.

## Daily use

| Task                                 | Command                                                                      |
| ------------------------------------ | ---------------------------------------------------------------------------- |
| Server state, links, T3 Connect      | `t3f status`                                                                 |
| Which hosts answer, with versions    | `t3f fleet` (`--discover` probes every tailnet peer)                         |
| Threads of the current project       | `t3f threads`                                                                |
| Start a task here or on another host | `t3f start "fix the flaky test" [--host homelab --project ~/src/x] [--wait]` |
| Follow up, read a thread             | `t3f send ID "now add tests" --wait`, `t3f show ID`                          |
| Pairing link for a new device        | `t3f pair --label NAME --ttl 10m`                                            |
| Server log                           | `t3f logs -f`                                                                |

`t3f` wraps `t3 thread`, `t3 environment`, `t3 pair` and `t3 auth`, which
work on the host without signing in; `--host` runs them over ssh, so a
homelab command needs the Tailscale SSH check approved. Inside a thread,
`@`-mention a machine or ask the agent to delegate to it.
**Settings → Environments → Load balancing** can pick a machine for new
threads.

### Project environments

T3 starts agents with the server's environment. It does not run direnv, and
setting the working directory does not activate nix-direnv. The unit covers
both ways agents run commands here:

- **bash** (Codex's and OpenCode's shell tools): `BASH_ENV` points at a hook
  that loads the direnv environment of each command's directory, about 0.1 s
  per command once nix-direnv has cached the dev shell.
- **The Nushell MCP server** (where Claude, following the global
  instructions, does its shell work): it starts in the thread's project and,
  seeing `T3_FLEET_DIRENV=1` from the unit, loads that directory's direnv
  environment once at start (`modules/tooling/ai/scripts/nu-mcp-config.nu`).
  A dev shell that takes over 20 s to build loads nothing there; enter the
  project once in a terminal to build it.

Only `.envrc` files you allowed load. A T3 worktree is a new path, so it
needs `direnv allow` once; a repository can run it from `t3.json`:

```json
{
  "scripts": [
    {
      "name": "Allow direnv",
      "command": "direnv allow",
      "runOnWorktreeCreate": true,
      "async": false
    }
  ]
}
```

### JJ repositories

T3 drives Git only (its source-control discovery marks Jujutsu as not
implemented); in a colocated repository it sees `.git`. Start JJ threads in
the project folder, the default (`"defaultThreadEnvMode": "local"` in
`t3.json` pins it), not with `--worktree`: a T3 worktree is a Git worktree
JJ does not track. The agent then follows the repository's own JJ rules,
such as creating its workspace with `ci start` or `jj workspace add`. T3's
branch, pull request and auto-pull features act on the Git side only.

## Updates and rollback

- **Update.** Move `nixpkgs-t3code` to a newer nixpkgs revision that ships
  the release (`nix flake lock --override-input nixpkgs-t3code github:NixOS/nixpkgs/REV`), or delete the input and the override once
  `nixpkgs-watch` says the main nixpkgs ships it. Deliver and activate as
  usual; activation restarts the server. Do not use `t3 update`, the in-app
  updater or `t3 service install`.
- **Rollback.** Revert the commit (or the input), deliver, and activate; or
  activate the previous home generation. Versions before 0.1.0 read the kept
  `state.sqlite` and miss threads created since.
- **Turn a host off.** Set `services.t3code = false` for it in
  `den/inventory.nix`. Its `~/.t3` stays; the desktop app's local
  environment can be switched back on in **Settings → Environments**.

## macOS

The inventory has no macOS hosts and the flake targets x86_64-linux only.
nixpkgs builds `t3code` for aarch64-darwin. On a Mac, install it and use
`t3 service install` (a launchd agent while you are logged in), run
`tailscale serve --bg --https=3773 http://127.0.0.1:3773`, and pair and
link as above.

## Verification (2026-10-29)

Before delivery, on asus, the unit's own command and environment ran as a
transient user unit against a throwaway T3 home and port, with a throwaway
flake project:

| Check                                                                         | Result                                                                   |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `nix fmt`, `prek`, `den-config-tests-asus`, `-homelab`, `tests.nix`           | pass                                                                     |
| The home's `t3code-bash-env` check (allowed `.envrc` loads, blocked does not) | pass                                                                     |
| Server 0.1.4 under systemd, ready at `/.well-known/t3/environment`            | pass; `peerLinks` and `mcpModeLimitHeader` capabilities on               |
| Journal keeps the log, drops the pairing banner                               | pass; no token, link or QR code                                          |
| MCP tool calls over `/mcp` (`t3 thread list`, `start`, `show`)                | pass                                                                     |
| Claude (Max login) and Codex (ChatGPT login) run threads under the unit       | pass, on claude-haiku-5-5 and gpt-6-luna                                 |
| Codex's commands see the project's dev shell                                  | pass: `probe=dev-shell-loaded hello=/nix/store/…-hello-2.12.3/bin/hello` |
| Nushell MCP config loads the dev shell with `T3_FLEET_DIRENV=1` only          | pass when run directly; Claude through it needs the activated home       |
| Server restart while a task runs                                              | pass: the run resumed and finished; all three threads kept               |
| Client-only desktop launcher on existing, missing and set settings files      | pass; keeps keys and mode                                                |

Not tested: macOS; anything on homelab, linked environments, the phone and
push notifications, which need the rollout below.
