# Fieldwork · XR workbench

Fieldwork merges the Agent Cockpit prototype with this repository’s Nix,
Nushell, and Jujutsu workflow in one browser-based spatial workspace with a
desktop companion. It uses Meta’s
Immersive Web SDK (IWSDK) for rendering, WebXR sessions, controller and hand
input, and UIKitML world panels. The desktop companion keeps its normal,
keyboard-accessible HTML editor and command console.

From this repository root, in Nushell, use Nix to supply the workbench's tools
without copying the working tree into the Nix store:

```nu
nix shell 'nixpkgs#nodejs_24' 'nixpkgs#pnpm' 'nixpkgs#python3' 'nixpkgs#d2' --command pnpm --dir xr-workbench/web install --frozen-lockfile
nix shell 'nixpkgs#nodejs_24' 'nixpkgs#pnpm' 'nixpkgs#python3' 'nixpkgs#d2' --command pnpm --dir xr-workbench/web run dev -- --repo .
```

The first command installs the pinned frontend dependencies from
`pnpm-lock.yaml`; the second starts the local Python workspace bridge and IWSDK’s HTTPS development
server. Follow its output to the local browser URL. The server also reports a
network URL for a headset on the same Wi-Fi network. Open that HTTPS address in
Quest Browser, accept its local development certificate warning if shown, and
select **Enter XR**. The workbench stays usable in the desktop browser when XR
is unavailable.

The IWSDK plugin currently caches a certificate **and private key** under
`xr-workbench/web/.iwsdk/https/`. Do not use `nix run path:.#xr-workbench`
while that generated file is inside this checkout: `path:` includes ignored
files and could copy the key into the Nix store. The Nix shell commands above
do not package this checkout.

## MCP sequence trace prototype

Enter XR from the main workbench page to see a seated **main menu**. Select
**MCP sequence demo** to open the recorded example without leaving the XR
session; use the demo's Previous/Next buttons to step through it, or **Main
menu** to return. The workbench's spatial panels have the same return action.
Select **Open workbench** to enter the existing workspace instead.

Alternatively, open `/mcp.html` on the same workbench URL to inspect a
**synthetic, redacted** MCP conversation directly. The bridge projects each
selected prefix of the trace into a
D2 sequence diagram and serves the resulting SVG to both the desktop view and
an IWSDK panel. Datastar keeps the desktop timeline in sync; UIKitML Previous
and Next buttons operate the same timeline using controller rays in Quest
Browser. Use the main page's **Explore MCP sequence trace** link to open it.
The standard workbench remains unchanged.

The trace teaches MCP protocol revision
[2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/changelog),
the stateless revision often called "MCP 2.0". It shows:

- `server/discover` in place of the removed `initialize` handshake and
  sessions; every request carries its protocol version and capabilities in
  `_meta`, so the second server is called without any handshake;
- a cacheable `tools/list` result with `ttlMs` and `cacheScope`;
- a `subscriptions/listen` stream, its acknowledgment, and a
  `notifications/tools/list_changed` tagged with its subscription ID;
- two overlapping tool calls correlated by request ID;
- a multi round-trip request: `tools/call` returns `input_required` with an
  elicitation and `requestState`, and the client retries under a new ID;
- a `-32602` protocol error for an unknown tool.

The trace does not cover the older handshake-based revisions or the deprecated
Roots, Sampling, and Logging features.

The launcher and development shell provide D2. This prototype does **not**
connect to live MCP clients or proxy server traffic; the fixture is deliberately
free of real arguments, file contents, and credentials. The 2D view can also be
shown in WayVR. A StardustXR-native frontend is not included.

## Interactive workspace

- Cockpit, arc, focus, and wall layouts, panel distance and scale, browser-local layout
  persistence, and JSON export. Panels are arranged about 1–2 metres from the
  viewer; no artificial locomotion is enabled.
- The cockpit layout places the agent exchange ahead, source and worktree
  controls on either side, and environment feedback below. Its desktop shell
  uses a forward reticle, input and return buses, and a three-part status
  dashboard. In XR those roles live on world-space UIKitML panels; the user’s
  camera stays still, so the interface works seated and does not simulate
  vehicle motion. Other layouts remain available if a different arrangement
  is more comfortable.
- A spatial exchange loop makes direction legible: configuration, chosen
  actions, and sample agent requests push in; JJ state, evaluation outcomes,
  command output, and typed answers pull back. The indicator animates the
  active direction and carries the latest result. Four UIKitML panels share
  the same state as the desktop inspector.
- Agent Cockpit brings the hosted prototype's capability HUD, paced token
  replay, and Jev typed-output cards into the workbench. The HUD inventories
  repository-owned instructions, skills, and client modules; it does not claim
  those are active in a running agent. Replay is a deterministic fixture and
  makes no model or tool calls. The **Pull selected command** action instead
  displays actual command output from the local workspace bridge. Jev inspection
  accepts pasted JSON and renders choice, noul, score, probabilities, and
  confidence as data, with a clear note that confidence is not correctness.
  The spatial agent panel shows input/output counts, the current exchange
  phase, and a short result preview so the push/pull loop is legible in XR.
- UIKitML panels use controller rays or hand interaction. Trigger panel
  buttons to open the configuration studio and agent cockpit, replay the agent
  fixture, pull selected command output, inspect JJ status and history,
  review the diff, evaluate the flake, or enter the repository dev shell. Hold
  grip to reposition a panel. Desktop controls expose the same actions.
- Source editing is in the desktop companion. Saves compare the original file
  hash, reject conflicting external edits, and atomically replace the file.
  Host inventory, system configuration, the root flake, and architecture notes
  are read-only. Nothing activates system configuration.
- Commands run only when selected. Output streams to the console, retains the
  latest 200,000 characters per command, and can be stopped. Flake evaluation
  does not build outputs.

Development-shell inspection uses the selected repository’s root flake, not
the template being edited. Editing a development template changes future
projects; it does not reconfigure an already instantiated project. Fieldwork
does not provide arbitrary shell access, remote agent control, an immersive
keyboard, or app-window streaming. The hosted Agent Cockpit Site remains a
prototype reference; this local app is the merged workbench because only the
local bridge can access the selected repository and command results.

## Development

Inside the repository dev shell, install the pinned dependencies once and run
the frontend and bridge together:

```nu
cd xr-workbench/web
pnpm install --frozen-lockfile
pnpm dev -- --repo ../..
```

The dev server uses IWSDK’s Vite plugin for local HTTPS and IWER desktop XR
emulation. Its secure network URL is the headset development loop; live edits
use Vite hot reload. `Ctrl+C` stops both the Vite runtime and the local bridge.

For a **desktop-only, loopback** preview when your browser cannot trust the
plugin's self-signed certificate, run from this checkout's root in Nushell
after installing dependencies as above:

```nu
FIELDWORK_HTTP_PREVIEW=1 nix shell 'nixpkgs#nodejs_24' 'nixpkgs#pnpm' 'nixpkgs#python3' 'nixpkgs#d2' --command pnpm --dir xr-workbench/web run dev -- --repo .
```

This disables HTTPS and binds Vite to `127.0.0.1` only. Use the printed
`http://127.0.0.1:PORT` URL (the port may differ if 8081 is occupied); loopback
HTTP still counts as a browser secure context. Do not use this mode for a Quest
on the LAN. The normal development command continues to serve HTTPS by default.

The bridge binds only to loopback, validates the forwarded local Host, uses a
random per-process session token, and rejects foreign origins. The Vite proxy
keeps browser API calls same-origin. Static assets and editable configuration
paths are explicitly enumerated; commands use argument arrays, never shell
interpolation. There is no filesystem browsing or arbitrary-command endpoint.
Use the repository’s existing JJ workflow for delivery. There is no build,
publish, rebase, merge, or activation action in the workbench.
