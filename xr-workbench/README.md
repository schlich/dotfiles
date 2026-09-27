# Fieldwork · XR workbench

Fieldwork merges the Agent Cockpit prototype with this repository’s Nix,
Nushell, and Jujutsu workflow in one browser-based spatial workspace with a
desktop companion. It uses Meta’s
Immersive Web SDK (IWSDK) for rendering, WebXR sessions, controller and hand
input, and UIKitML world panels. The desktop companion keeps its normal,
keyboard-accessible HTML editor and command console.

From this repository root, in Nushell:

```nu
nix run path:.#xr-workbench
```

The launcher installs the pinned frontend dependencies from `pnpm-lock.yaml`,
starts the local Python workspace bridge, and runs IWSDK’s HTTPS development
server. Follow its output to the local browser URL. The server also reports a
network URL for a headset on the same Wi-Fi network. Open that HTTPS address in
Quest Browser, accept its local development certificate warning if shown, and
select **Enter XR**. The workbench stays usable in the desktop browser when XR
is unavailable.

To use another checkout:

```nu
nix run path:.#xr-workbench -- --repo /absolute/path/to/dotfiles
```

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

The bridge binds only to loopback, validates the forwarded local Host, uses a
random per-process session token, and rejects foreign origins. The Vite proxy
keeps browser API calls same-origin. Static assets and editable configuration
paths are explicitly enumerated; commands use argument arrays, never shell
interpolation. There is no filesystem browsing or arbitrary-command endpoint.
Use the repository’s existing JJ workflow for delivery. There is no build,
publish, rebase, merge, or activation action in the workbench.
