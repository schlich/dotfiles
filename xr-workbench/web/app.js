import { createCockpit } from "./cockpit.js";
const $ = (id) => document.getElementById(id);
const panels = [
  {
    id: "config",
    title: "Push · Source",
    subtitle: "Nix · XR integration",
    icon: "↑",
    lines: [
      "LIVE CONFIGURATION",
      "XR policy + dev templates",
      "Edit on desktop · save to push",
    ],
    flowStatus: "Source changes push into the worktree.",
    action: "evaluate",
    actionLabel: "Evaluate flake",
  },
  {
    id: "changes",
    title: "Worktree · Exchange",
    subtitle: "Jujutsu · current topic",
    icon: "⇄",
    lines: [
      "JUJUTSU WORKTREE",
      "Push changes in",
      "Pull status, diffs, and results out",
    ],
    flowStatus: "Ready for a change or command.",
    action: "status",
    actionLabel: "Refresh JJ status",
  },
  {
    id: "environment",
    title: "Pull · Feedback",
    subtitle: "Nix · Nushell",
    icon: "↓",
    lines: [
      "DEVELOPMENT SHELL",
      "Environment details + command output",
      "Nix + Nushell + devenv templates",
    ],
    flowStatus: "Command output and evaluation results return here.",
    action: "environment",
    actionLabel: "Inspect dev shell",
  },
  {
    id: "agent",
    title: "Agent · Cockpit",
    subtitle: "Capabilities · tokens · Jev",
    icon: "◇",
    lines: [
      "AGENT COCKPIT",
      "Repository capability inventory",
      "Push requests · pull typed output",
    ],
    flowStatus: "PUSH → request · ← PULL output",
    action: null,
    actionLabel: "Open cockpit",
  },
];
let token,
  session,
  currentFile,
  dirty = false,
  scene,
  selectedJob = "",
  jobs = [],
  activePanel = "config",
  lastFlowSignature = "",
  cockpit;
let settings = { layout: "cockpit", distance: 1.7, scale: 1, positions: {} };
try {
  const saved = JSON.parse(localStorage.getItem("fieldwork-layout") || "null");
  if (saved && ["cockpit", "arc", "focus", "wall"].includes(saved.layout)) {
    settings = {
      ...settings,
      layout: saved.layout,
      distance: Math.min(2.2, Math.max(1, Number(saved.distance) || 1.7)),
      scale: Math.min(1.4, Math.max(0.65, Number(saved.scale) || 1)),
      positions: Object.fromEntries(
        Object.entries(saved.positions || {}).filter(
          ([id, p]) =>
            panels.some((panel) => panel.id === id) &&
            Array.isArray(p) &&
            p.length === 3 &&
            p.every((v) => Number.isFinite(v) && Math.abs(v) < 10),
        ),
      ),
    };
  }
} catch {
  /* Storage is optional. */
}

let noticeTimer;
function notice(message) {
  $("notice").textContent = message;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => {
    $("notice").textContent = "";
  }, 7000);
}
function updateFlow(direction, title, detail) {
  panels[0].flowStatus = "YOU → WORKTREE · edits and chosen actions";
  panels[1].flowStatus = `${direction === "push" ? "PUSH →" : "← PULL"} ${title} · ${detail}`;
  panels[2].flowStatus =
    direction === "pull"
      ? `← PULL · ${title} · ${detail}`
      : "← PULL · Waiting for worktree feedback";
  if (activePanel === "agent")
    panels[3].flowStatus = `${direction === "push" ? "PUSH →" : "← PULL"} ${title} · ${detail}`;
  $("flow-summary").textContent = `${title} · ${detail}`;
  $("flow-legend").dataset.direction = direction;
  $("viewport").dataset.direction = direction;
  if (direction === "push") $("hud-push").textContent = title;
  else $("hud-pull").textContent = title;
  $("hud-system").textContent =
    direction === "push" ? "TRANSMITTING" : "RECEIVING";
  scene?.refresh();
}
async function api(path, body) {
  const response = await fetch(`/api/${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      "Content-Type": "application/json",
      "X-Workbench-Token": token || "",
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(12000),
  });
  const result = await response.json();
  if (!response.ok)
    throw new Error(result.error || `Request failed (${response.status})`);
  return result;
}
function persist() {
  try {
    localStorage.setItem("fieldwork-layout", JSON.stringify(settings));
  } catch {
    $("saved-state").textContent =
      "Storage unavailable · export to keep your layout";
  }
}
function tab(name) {
  for (const key of ["config", "console", "agent", "workflow"]) {
    $(`${key}-pane`).hidden = name !== key;
    $(`tab-${key}`).setAttribute("aria-selected", String(name === key));
    $(`tab-${key}`).tabIndex = name === key ? 0 : -1;
  }
  $("inspector-title").textContent = {
    config: "Configuration studio",
    console: "Workspace console",
    agent: "Agent cockpit",
    workflow: "From idea to delivery",
  }[name];
}
const tabs = [...document.querySelectorAll("[role=tab]")];
tabs.forEach((button, index) => {
  button.onclick = () => tab(button.id.slice(4));
  button.onkeydown = (event) => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const next =
      event.key === "Home"
        ? 0
        : event.key === "End"
          ? tabs.length - 1
          : (index + (event.key === "ArrowRight" ? 1 : tabs.length - 1)) %
            tabs.length;
    tabs[next].click();
    tabs[next].focus();
  };
});
function selectPanel(id) {
  activePanel = id;
  document
    .querySelectorAll("[data-panel]")
    .forEach((button) =>
      button.setAttribute("aria-pressed", String(button.dataset.panel === id)),
    );
  scene?.select(id);
  tab(id === "config" ? "config" : id === "agent" ? "agent" : "console");
}
for (const panel of panels) {
  const button = document.createElement("button");
  button.dataset.panel = panel.id;
  button.setAttribute("aria-pressed", String(panel.id === activePanel));
  const icon = document.createElement("span");
  icon.className = "panel-icon";
  icon.textContent = panel.icon;
  const text = document.createElement("span");
  text.textContent = panel.title;
  const subtitle = document.createElement("small");
  subtitle.textContent = panel.subtitle;
  text.append(subtitle);
  button.append(icon, text);
  button.onclick = () => selectPanel(panel.id);
  $("panels").append(button);
}
function updateLayout() {
  document
    .querySelectorAll("[data-layout]")
    .forEach((button) =>
      button.setAttribute(
        "aria-pressed",
        String(button.dataset.layout === settings.layout),
      ),
    );
  $("layout-name").textContent = `/ ${settings.layout.toUpperCase()}`;
  $("distance").value = settings.distance;
  $("scale").value = settings.scale;
  $("distance-value").textContent = `${settings.distance.toFixed(1)} m`;
  $("scale-value").textContent = `${Math.round(settings.scale * 100)}%`;
  scene?.layout(settings);
  persist();
}
document.querySelectorAll("[data-layout]").forEach(
  (button) =>
    (button.onclick = () => {
      settings.layout = button.dataset.layout;
      settings.positions = {};
      updateLayout();
    }),
);
for (const id of ["distance", "scale"])
  $(id).oninput = () => {
    settings[id] = Number($(id).value);
    settings.positions = {};
    updateLayout();
  };
$("reset-view").onclick = () => {
  settings.positions = {};
  updateLayout();
  scene?.reset();
};
$("export-layout").onclick = () => {
  const url = URL.createObjectURL(
    new Blob([JSON.stringify({ version: 1, ...settings }, null, 2)], {
      type: "application/json",
    }),
  );
  const link = document.createElement("a");
  link.href = url;
  link.download = "fieldwork-layout.json";
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
};
function markEditor() {
  $("save-file").disabled = !currentFile?.editable || !dirty;
  $("editor-state").textContent = dirty
    ? "UNSAVED DRAFT"
    : currentFile?.editable
      ? "EDITABLE SOURCE"
      : "READ ONLY";
}
async function loadFile(path) {
  if (
    dirty &&
    !confirm("Discard the unsaved editor draft and load this source?")
  ) {
    $("file-select").value = currentFile.path;
    return;
  }
  try {
    const file = await api(`file?path=${encodeURIComponent(path)}`);
    currentFile = file;
    dirty = false;
    $("editor").value = file.content;
    $("editor").readOnly = !file.editable;
    $("file-select").value = path;
    $("file-note").textContent = file.editable
      ? "Save writes this source in your workspace. Review the diff and evaluate before delivery. No system activation."
      : "Reference source. Host facts and system configuration are read-only here.";
    markEditor();
    panels[0].lines = [
      "LIVE CONFIGURATION",
      path,
      file.editable ? "Editable on desktop companion" : "Read-only reference",
    ];
    updateFlow("pull", "Source loaded", path);
    scene?.refresh();
  } catch (error) {
    notice(error.message);
  }
}
$("file-select").onchange = () => loadFile($("file-select").value);
$("reload-file").onclick = () => loadFile($("file-select").value);
$("editor").oninput = () => {
  dirty = $("editor").value !== currentFile?.content;
  markEditor();
  if (dirty)
    updateFlow("push", "Draft ready", "Save to push it into the worktree");
};
$("save-file").onclick = async () => {
  if (!currentFile?.editable || !dirty) return;
  const file = currentFile,
    content = $("editor").value;
  $("save-file").disabled = true;
  try {
    const result = await api("file", {
      path: file.path,
      revision: file.revision,
      content,
    });
    if (currentFile === file) {
      currentFile.revision = result.revision;
      currentFile.content = content;
      dirty = $("editor").value !== content;
    }
    notice("Saved to your topic workspace. Review the diff when ready.");
    updateFlow("push", "Source saved to worktree", file.path);
  } catch (error) {
    notice(error.message);
  } finally {
    markEditor();
  }
};
window.addEventListener("beforeunload", (event) => {
  if (dirty) {
    event.preventDefault();
    event.returnValue = "";
  }
});
function showJob() {
  const job = jobs.find((job) => job.id === selectedJob);
  $("console-output").textContent = job
    ? `$ ${job.command.join(" ")}\n\n${job.output || "Waiting for output…"}\n\n[${job.state}${job.exitCode !== null ? ` · exit ${job.exitCode}` : ""}]`
    : "Run a command to see real output from your workspace.";
  $("stop-job").disabled = job?.state !== "running";
}
async function poll() {
  try {
    jobs = await api("jobs");
    $("connection").textContent = "Workspace connected";
    $("connection-dot").classList.add("online");
    $("hud-link").textContent = "WORKSPACE ONLINE";
    $("job-select").replaceChildren(
      ...jobs.map((job) => new Option(`${job.action} · ${job.state}`, job.id)),
    );
    if (!selectedJob && jobs.length) selectedJob = jobs.at(-1).id;
    $("job-select").value = selectedJob;
    showJob();
    const activeFlowJob = jobs.find((job) => job.id === selectedJob);
    if (activeFlowJob) {
      const signature = `${activeFlowJob.id}:${activeFlowJob.state}:${activeFlowJob.output.length}`;
      if (signature !== lastFlowSignature) {
        lastFlowSignature = signature;
        const latest =
          activeFlowJob.output.split("\n").filter(Boolean).at(-1) ||
          activeFlowJob.state;
        panels[2].lines = [
          activeFlowJob.state.toUpperCase(),
          activeFlowJob.action,
          ...activeFlowJob.output.split("\n").filter(Boolean).slice(-2),
        ];
        updateFlow(
          "pull",
          `${activeFlowJob.action} · ${activeFlowJob.state}`,
          latest,
        );
      }
    }
    cockpit?.sync(activeFlowJob);
    const running = jobs.some((job) => job.state === "running");
    document.querySelectorAll("[data-action]").forEach((button) => {
      button.disabled = running;
    });
    for (const panel of panels) {
      if (!panel.action) continue;
      const recent = jobs.findLast((job) => job.action === panel.action);
      if (recent)
        panel.lines = [
          recent.state.toUpperCase(),
          ...recent.output.split("\n").filter(Boolean).slice(-4),
        ];
    }
    scene?.refresh();
  } catch (error) {
    $("connection").textContent = "Bridge disconnected · retrying";
    $("connection-dot").classList.remove("online");
    $("hud-link").textContent = "LINK LOST";
  }
  setTimeout(poll, 1500);
}
async function run(action) {
  updateFlow("push", `Sending ${action}`, "into the active worktree");
  try {
    const job = await api("run", { action });
    selectedJob = job.id;
    jobs.push(job);
    showJob();
    tab("console");
    notice(`Started ${action}`);
    lastFlowSignature = "";
  } catch (error) {
    notice(error.message);
    updateFlow("pull", "Action rejected", error.message);
  }
}
document
  .querySelectorAll("[data-action]")
  .forEach((button) => (button.onclick = () => run(button.dataset.action)));
cockpit = createCockpit({
  api,
  panel: panels[3],
  flow: {
    update: updateFlow,
    refresh: () => scene?.refresh(),
    notice,
    selectedJob: () => jobs.find((job) => job.id === selectedJob),
  },
});
$("job-select").onchange = () => {
  selectedJob = $("job-select").value;
  showJob();
};
$("stop-job").onclick = async () => {
  try {
    await api("stop", { id: selectedJob });
    notice("Stopping command…");
  } catch (error) {
    notice(error.message);
  }
};
updateLayout();
try {
  session = await api("session");
  token = session.token;
  $("repo-path").textContent = session.repo;
  $("repo-name").textContent = session.repo.split("/").at(-1);
  $("file-select").replaceChildren(
    ...session.files.map(
      (file) =>
        new Option(`${file.editable ? "✎ " : ""}${file.path}`, file.path),
    ),
  );
  await loadFile(session.files[0].path);
  cockpit.loadCapabilities();
  poll();
} catch (error) {
  notice(`Cannot connect: ${error.message}`);
  $("connection").textContent = "Bridge unavailable · reload to reconnect";
}
try {
  const { createScene } = await import("/scene.js");
  scene = await createScene($("viewport"), panels, {
    select: selectPanel,
    run,
    notice,
  });
  updateLayout();
  scene.select(activePanel);
} catch (error) {
  $("scene-fallback").hidden = false;
  $("enter-xr").textContent = "Desktop mode";
  notice(
    `Desktop controls are ready. Spatial view unavailable: ${error.message}`,
  );
}
window.addEventListener("fieldwork:action", (event) => {
  const action = event.detail?.action;
  if (action === "config") selectPanel("config");
  else if (action === "agent") selectPanel("agent");
  else if (action === "agent-replay") {
    selectPanel("agent");
    cockpit.replay();
  } else if (action === "agent-live") {
    selectPanel("agent");
    cockpit.live(jobs.find((job) => job.id === selectedJob));
  } else if (action === "jev") {
    selectPanel("agent");
    $("jev-json").focus();
  } else if (action) run(action);
});
