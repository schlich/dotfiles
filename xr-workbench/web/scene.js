import { World } from "@iwsdk/core";
import projectOptions from "virtual:iwsdk-project";
import { PanelSystem } from "./src/panels.js";

const panelIds = [
  "configuration-panel",
  "changes-panel",
  "environment-panel",
  "agent-panel",
];
const panelBaseScale = 0.0017;

export async function createScene(container, panels, callbacks) {
  const world = await World.create(container, projectOptions);
  world.registerSystem(PanelSystem);
  let selectedPanel = "config";
  let currentSettings = {
    layout: "cockpit",
    distance: 1.7,
    scale: 1,
    positions: {},
  };

  function layout(settings) {
    currentSettings = settings;
    const focusedIndex = panels.findIndex(
      (panel) => panel.id === selectedPanel,
    );
    panelIds.forEach((id, index) => {
      const object = world.getSceneObject(id);
      if (!object) return;
      const offset = index - (panelIds.length - 1) / 2;
      const positions = settings.positions || {};
      if (positions[panels[index].id])
        object.position.fromArray(positions[panels[index].id]);
      else if (settings.layout === "cockpit") {
        const places = {
          agent: [0, 1.67, -settings.distance],
          config: [-1.02, 1.48, -settings.distance - 0.18],
          changes: [1.02, 1.48, -settings.distance - 0.18],
          environment: [0, 0.86, -settings.distance - 0.28],
        };
        object.position.set(...places[panels[index].id]);
      } else if (settings.layout === "wall")
        object.position.set(offset * 0.95, 1.55, -settings.distance);
      else if (settings.layout === "focus") {
        const focusOffset = index - focusedIndex;
        object.position.set(
          focusOffset * 0.83,
          focusOffset ? 1.48 : 1.62,
          -settings.distance - (focusOffset ? 0.35 : 0),
        );
      } else
        object.position.set(
          Math.sin(offset * 0.55) * settings.distance,
          1.55,
          -Math.cos(offset * 0.55) * settings.distance,
        );
      object.scale.setScalar(
        panelBaseScale *
          settings.scale *
          (settings.layout === "focus" && panels[index].id !== selectedPanel
            ? 0.82
            : 1) *
          (panels[index].id === selectedPanel ? 1.04 : 1),
      );
      object.lookAt(0, 1.55, 0.5);
    });
    refresh();
  }

  const enterButton = document.getElementById("enter-xr");
  const supported = Boolean(
    window.isSecureContext &&
      navigator.xr &&
      (await navigator.xr
        .isSessionSupported("immersive-vr")
        .catch(() => false)),
  );
  let immersive = false;
  enterButton.disabled = !supported;
  enterButton.textContent = supported ? "Enter XR ↗" : "Desktop mode";
  enterButton.title = supported
    ? "Open the spatial workspace in your headset"
    : "XR is unavailable in this browser context";
  enterButton.onclick = async () => {
    enterButton.disabled = true;
    try {
      if (immersive) await world.exitXR();
      else await world.launchXR();
    } catch (error) {
      callbacks.notice(`Could not change XR session: ${error.message}`);
    } finally {
      enterButton.disabled = false;
    }
  };
  const unsubscribe = world.visibilityState.subscribe((state) => {
    immersive = state !== "non-immersive";
    enterButton.textContent =
      state === "non-immersive" ? "Enter XR ↗" : "Exit XR";
  });

  function reset() {
    layout({ ...currentSettings, positions: {} });
  }
  function select(id) {
    selectedPanel = id;
    layout(currentSettings);
  }
  function refresh() {
    for (const [index, panel] of panels.entries()) {
      const element = world
        .getSceneObject(panelIds[index])
        ?.getElementById("panel-status");
      if (element) element.textContent = panel.lines.join("  ·  ");
      const flowElement = world
        .getSceneObject(panelIds[index])
        ?.getElementById("flow-status");
      if (flowElement) {
        flowElement.textContent = panel.flowStatus || "";
        flowElement.classList.toggle(
          "pull",
          panel.flowStatus?.startsWith("← PULL") || false,
        );
      }
      if (panels[index].id === "agent") {
        const metrics = panel.metrics || {};
        for (const [elementId, value] of [
          ["agent-state", metrics.state || "STANDBY"],
          ["input-gauge", metrics.input || "0 / 0"],
          ["output-gauge", metrics.output || "0 / 0"],
          [
            "agent-preview",
            metrics.preview || "Ready to inspect the exchange.",
          ],
        ]) {
          const gauge = world
            .getSceneObject(panelIds[index])
            ?.getElementById(elementId);
          if (gauge) gauge.textContent = value;
        }
      }
    }
  }

  reset();
  return {
    layout,
    reset,
    refresh,
    select,
    dispose() {
      unsubscribe();
    },
  };
}
