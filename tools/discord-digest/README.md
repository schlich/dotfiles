# discord-digest

Once a day on homelab, reads the new messages in every Discord channel you
can see, asks Claude which ones are worth your time, and renders a dashboard
of the findings: releases and announcements, things that bear on your stack,
and high-signal discussion. `modules/nixos/discord-digest.nix` runs it, and
`modules/nixos/homelab.nix` turns it on.

> **It runs as your account.** It authenticates with your user token,
> which makes it a self-bot. Discord's terms forbid self-bots, and an
> account caught running one can be banned. To keep that risk low, the
> client only reads, waits between requests, and honours every rate limit,
> but the risk is never zero.

## Turning it on

The digest stays off on homelab, and homelab's build warns, until its
credentials exist. Encrypt them for homelab's host key and your own from
this repository's `secrets/` directory:

```nu
cd secrets
nix run --inputs-from path:.. agenix -- -e discord-digest/env.age
```

In the editor that opens, write two lines:

```
DISCORD_TOKEN=<your user token>
ANTHROPIC_API_KEY=<an Anthropic API key>
```

To get your token, open Discord in a browser, open the developer tools'
Network tab, reload, and copy the `Authorization` header from any request to
`discord.com/api`. Changing your password invalidates it, and then the run
fails with a 401 until you replace it.

Commit `secrets/discord-digest/env.age` and deliver. The next switch on
homelab starts the timer, the static server, and Tailscale Serve.

## Using it

- **Dashboard:** `https://homelab.<tailnet>.ts.net:7443`, from tailnet
  devices only.
- **Schedule:** daily at 06:00 (`services.discord-digest.schedule`). A run
  missed while homelab was off happens at the next boot.
- **Run now:** `sudo systemctl start discord-digest` on homelab. Follow it
  with `journalctl -u discord-digest -f`.
- **What it reads:** set `services.discord-digest.settings.channels` with
  the keys from `config.example.toml`. An empty include list means every
  channel you can read.
- **What counts as interesting:** edit `interests.md`. Triage scores every
  message against it.

Each channel remembers the last message it read, so a run reads only
what's new. A channel's first run reads back `first_run_hours`. A channel
you can't read is skipped for a week, then tried again. State lives in
`/var/lib/discord-digest`.

## How it decides

1. **Triage** (`triage_model`, Claude Haiku 5.5 by default): each channel's
   new messages, with the server, channel, and topic, go out in one request
   that returns structured findings. Each finding has a category, a 1–10
   score, a reason, and the source message IDs. Message text is treated as
   untrusted data, and any ID the model invents is dropped.
1. **Briefing** (`overview_model`, Claude Opus 5.5 by default): reads the
   findings scored at or above `min_score`, never raw messages, and writes
   the bullet points at the top of the dashboard. It opts into server-side
   refusal fallbacks, so a declined request falls back to another model
   instead of failing.

At about 100 active channels the triage step reads a few million tokens a
day. On Haiku that comes to well under a dollar.

## Dashboard keys

The bar at the bottom always shows the current mode and its keys.

| Mode     | Keys                                                                                                                                                                                              |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `NORMAL` | `j`/`k` move · `o`/`Enter` open in Discord · `x` mark seen · `h` hide seen · `/` search · `1 2 3` toggle categories · `+`/`-` min score · `s`/`S` server · `[`/`]` older/newer run · `a` all runs |
| `SEARCH` | type to filter · `Enter` keep the filter and return to `NORMAL` · `Esc` clear it and return                                                                                                       |

Seen marks live in your browser's local storage.

## Developing

The package builds from nixpkgs' Python packages (`package.nix`), and its
tests run in the build: the `discord-digest` flake check. To iterate
without Nix, run `uv run --with pytest pytest` in this directory.
