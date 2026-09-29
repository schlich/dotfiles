import { createSystem } from "@iwsdk/core";

const controls = [
  ["configuration-panel", "inspect-source", "config"],
  ["configuration-panel", "evaluate-flake", "evaluate"],
  ["changes-panel", "refresh-status", "status"],
  ["changes-panel", "review-diff", "diff"],
  ["changes-panel", "change-history", "history"],
  ["environment-panel", "inspect-environment", "environment"],
  ["agent-panel", "open-cockpit", "agent"],
  ["agent-panel", "replay-agent", "agent-replay"],
  ["agent-panel", "pull-command", "agent-live"],
  ["agent-panel", "inspect-jev", "jev"],
  ["main-menu", "menu-workbench", "menu-workbench"],
  ["main-menu", "menu-mcp", "menu-mcp"],
  ["mcp-controls", "trace-previous", "trace-previous"],
  ["mcp-controls", "trace-next", "trace-next"],
  ["mcp-controls", "trace-menu", "menu-home"],
  ["configuration-panel", "config-menu", "menu-home"],
  ["changes-panel", "changes-menu", "menu-home"],
  ["environment-panel", "environment-menu", "menu-home"],
  ["agent-panel", "agent-menu", "menu-home"],
];

export class PanelSystem extends createSystem({}) {
  init() {
    for (const [panelId, controlId, action] of controls) {
      const control = this.world
        .getSceneObject(panelId)
        ?.getElementById(controlId);
      if (!control) continue;
      const onClick = () =>
        window.dispatchEvent(
          new CustomEvent("fieldwork:action", { detail: { action } }),
        );
      control.addEventListener("click", onClick);
      this.cleanupFuncs.push(() =>
        control.removeEventListener("click", onClick),
      );
    }
  }
}
