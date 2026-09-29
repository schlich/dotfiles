import { World } from "@iwsdk/core";
import projectOptions from "virtual:iwsdk-project";
import { createTraceSurface } from "./src/trace-surface.js";

const $ = (id) => document.getElementById(id);
let events = [];
let token;
let world;
let surface;
let latestStep = -1;
let pendingStep = 0;
let requestNumber = 0;
const enter = $("enter-xr");

function nextFrame() {
  return new Promise((resolve) => requestAnimationFrame(resolve));
}

async function waitForScenePanels() {
  const panels = [
    ["configuration-panel", "panel-status"],
    ["changes-panel", "panel-status"],
    ["environment-panel", "panel-status"],
    ["agent-panel", "panel-status"],
    ["mcp-controls", "trace-step"],
    ["main-menu", "menu-mcp"],
  ];
  const deadline = performance.now() + 15000;

  while (performance.now() < deadline) {
    const missing = panels.filter(
      ([panelId, elementId]) =>
        world.getSceneObject(panelId)?.getElementById(elementId) == null,
    );
    if (!missing.length) return;
    await nextFrame();
  }

  throw new Error("Scene panels did not finish loading within 15 seconds");
}

function message(error) {
  $("trace-error").textContent = error ? String(error) : "";
}

async function api(path) {
  const response = await fetch(`/api/${path}`, {
    headers: { "X-Workbench-Token": token },
    signal: AbortSignal.timeout(12000),
  });
  if (!response.ok) throw new Error(`Bridge returned ${response.status}`);
  return response;
}

function controls() {
  return world?.getSceneObject("mcp-controls");
}

async function showStep(step) {
  if (!events.length || step < 0 || step >= events.length) return false;
  if (step === latestStep) return true;
  const request = ++requestNumber;
  const event = events[step];
  try {
    const response = await api(`mcp/diagram?step=${step}`);
    const blob = await response.blob();
    if (request !== requestNumber) return false;
    if (!(await surface.show(blob))) return false;
    const previous = $("diagram").dataset.url;
    const next = URL.createObjectURL(blob);
    $("diagram").src = next;
    $("diagram").dataset.url = next;
    if (previous) URL.revokeObjectURL(previous);
    latestStep = step;
    $("event-summary").textContent =
      `${event.direction.toUpperCase()} · ${event.server} · ${event.summary}`;
    $("event-detail").textContent = event.detail;
    const correlation =
      event.requestId !== null
        ? `request ${event.requestId}`
        : event.subscriptionId != null
          ? `notification on subscription ${event.subscriptionId}`
          : "one-way notification";
    $("event-pair").textContent =
      `Method ${event.method} · ${correlation} · event ${step + 1}/${events.length}`;
    const panel = controls();
    const title = panel?.getElementById("trace-step");
    const detail = panel?.getElementById("trace-detail");
    if (title)
      title.textContent = `EVENT ${step + 1}/${events.length} · ${event.direction.toUpperCase()}${event.requestId === null ? "" : ` #${event.requestId}`}`;
    if (detail) detail.textContent = event.summary;
    message("");
    return true;
  } catch (error) {
    message(`Could not display sequence: ${error.message}`);
    return false;
  }
}

// Datastar owns the desktop step signal. UIKitML buttons dispatch the same
// change through a DOM event, so both controls share one render path.
window.renderTrace = (step) => {
  pendingStep = Number(step);
  void showStep(pendingStep);
};

async function start() {
  enter.disabled = true;
  enter.textContent = "Preparing scene…";
  try {
    const session = await fetch("/api/session").then((response) =>
      response.json(),
    );
    token = session.token;
    events = (await (await api("mcp/trace")).json()).events;
    const container = $("scene");
    world = await World.create(container, projectOptions);
    for (const id of [
      "configuration-panel",
      "changes-panel",
      "environment-panel",
      "agent-panel",
      "main-menu",
    ]) {
      const panel = world.getSceneObject(id);
      if (panel) panel.visible = false;
    }
    const panel = controls();
    if (panel) {
      panel.visible = true;
      for (const [id, delta] of [
        ["trace-previous", -1],
        ["trace-next", 1],
      ]) {
        panel.getElementById(id)?.addEventListener("click", () => {
          const step = Math.max(
            0,
            Math.min(events.length - 1, pendingStep + delta),
          );
          // A native input event updates Datastar's bound signal and desktop controls.
          const slider = $("step");
          slider.value = String(step);
          slider.dispatchEvent(new Event("input", { bubbles: true }));
        });
      }
      panel
        .getElementById("trace-menu")
        ?.addEventListener("click", async () => {
          await world.exitXR();
          window.location.assign("/");
        });
    }
    surface = createTraceSurface(world);
    surface.setVisible(true);
    await waitForScenePanels();
    if (!(await showStep(pendingStep)))
      throw new Error("The first sequence diagram could not be prepared");
    // Let UIKit finish its first layout and upload the diagram before the XR
    // framebuffer becomes active; WebGL textures cannot be resized in-session.
    await nextFrame();
    await nextFrame();

    const supported = Boolean(
      window.isSecureContext &&
        navigator.xr &&
        (await navigator.xr
          .isSessionSupported("immersive-vr")
          .catch(() => false)),
    );
    enter.disabled = !supported;
    enter.textContent = supported ? "Enter XR ↗" : "Desktop mode";
    let immersive = false;
    enter.onclick = async () => {
      try {
        if (immersive) await world.exitXR();
        else await world.launchXR();
      } catch (error) {
        message(error.message);
      }
    };
    world.visibilityState.subscribe((state) => {
      immersive = state !== "non-immersive";
      enter.textContent = state === "non-immersive" ? "Enter XR ↗" : "Exit XR";
    });
    enter.disabled = !supported;
  } catch (error) {
    enter.disabled = true;
    enter.textContent = "Scene unavailable";
    message(`MCP trace unavailable: ${error.message}`);
  }
}

void start();
