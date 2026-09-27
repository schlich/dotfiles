import { AssetType, defineAssets } from "@iwsdk/core";

export default defineAssets({
  "configuration-panel": {
    name: "Configuration",
    type: AssetType.UIKitML,
    url: "/ui/configuration-panel.uikitml",
  },
  "changes-panel": {
    name: "Changes",
    type: AssetType.UIKitML,
    url: "/ui/changes-panel.uikitml",
  },
  "environment-panel": {
    name: "Environment",
    type: AssetType.UIKitML,
    url: "/ui/environment-panel.uikitml",
  },
  "agent-panel": {
    name: "Agent Cockpit",
    type: AssetType.UIKitML,
    url: "/ui/agent-panel.uikitml",
  },
});
