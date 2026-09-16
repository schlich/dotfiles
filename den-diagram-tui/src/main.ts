import { readFile } from "node:fs/promises";
import {
  BoxRenderable,
  ScrollBoxRenderable,
  TextRenderable,
  createCliRenderer,
} from "@opentui/core";
import { layoutGraph } from "./layout";
import {
  normalizeGraph,
  parseMermaid,
  type DiagramGraph,
  type DiagramNode,
} from "./model";

const colors = {
  background: "#111827",
  panel: "#172033",
  panelBright: "#1f2a44",
  text: "#d7e2f0",
  muted: "#8ea2bd",
  accent: "#7dd3fc",
  green: "#86efac",
  yellow: "#fde68a",
  border: "#334155",
};

const inputPath =
  process.argv[2] ??
  new URL("../examples/fleet.json", import.meta.url).pathname;
const renderer = await createCliRenderer({ exitOnCtrlC: true });

let graph: DiagramGraph;
let selectedIndex = 0;
let diagramText: TextRenderable;
let inspectorText: TextRenderable;
let statusText: TextRenderable;

function terminalWidth(): number {
  return Math.max(60, process.stdout.columns ?? 100);
}

async function loadGraph(): Promise<DiagramGraph> {
  const source = await readFile(inputPath, "utf8");
  try {
    return normalizeGraph(JSON.parse(source));
  } catch {
    return parseMermaid(source);
  }
}

function selectedNode(): DiagramNode | undefined {
  return graph.nodes[selectedIndex];
}

function inspectorContent(): string {
  const node = selectedNode();
  if (!node) return "No node selected";
  const connected = graph.edges.filter(
    (edge) => edge.from === node.id || edge.to === node.id,
  );
  const scope = graph.scopes.find((item) => item.id === node.scope);
  const lines = [
    `◆ ${node.label}`,
    "",
    `id      ${node.id}`,
    node.kind ? `kind    ${node.kind}` : "",
    node.type ? `type    ${node.type}` : "",
    node.scope ? `scope   ${scope?.label ?? node.scope}` : "",
    node.host ? `host    ${node.host}` : "",
    node.class ? `class   ${node.class}` : "",
    node.description ? `\n${node.description}` : "",
    "",
    `edges   ${connected.length}`,
    ...connected.map((edge) => {
      const direction = edge.from === node.id ? "→" : "←";
      const other = edge.from === node.id ? edge.to : edge.from;
      return `  ${direction} ${other}${edge.label ? ` (${edge.label})` : ""}`;
    }),
  ];
  return lines.filter(Boolean).join("\n");
}

function render(): void {
  const layout = layoutGraph(
    graph,
    Math.max(40, Math.floor(terminalWidth() * 0.72)),
  );
  diagramText.content = layout.lines.join("\n") || "(empty graph)";
  inspectorText.content = inspectorContent();
  const selected = graph.nodes.length === 0 ? 0 : selectedIndex + 1;
  statusText.content = `${graph.name}  ·  ${graph.nodes.length} nodes  ·  ${graph.edges.length} edges  ·  selected ${selected}/${graph.nodes.length}`;
}

const root = new BoxRenderable(renderer, {
  width: "100%",
  height: "100%",
  flexDirection: "column",
  backgroundColor: colors.background,
});
const header = new TextRenderable(renderer, {
  content: "  DEN DIAGRAM TUI",
  fg: colors.accent,
  height: 2,
});
const body = new BoxRenderable(renderer, {
  flexDirection: "row",
  flexGrow: 1,
  gap: 1,
  paddingLeft: 1,
  paddingRight: 1,
});
const diagramPanel = new BoxRenderable(renderer, {
  flexGrow: 1,
  flexDirection: "column",
  backgroundColor: colors.panel,
  padding: 1,
});
const diagramScroll = new ScrollBoxRenderable(renderer, {
  flexGrow: 1,
  scrollY: true,
  scrollX: true,
  backgroundColor: colors.panel,
  scrollbarOptions: { showArrows: false },
});
diagramText = new TextRenderable(renderer, {
  content: "Loading…",
  fg: colors.text,
});
diagramScroll.add(diagramText);
diagramPanel.add(
  new TextRenderable(renderer, {
    content: "GRAPH  ↑↓ select  ←→/wheel scroll",
    fg: colors.muted,
    height: 2,
  }),
);
diagramPanel.add(diagramScroll);

const inspectorPanel = new BoxRenderable(renderer, {
  width: 32,
  flexDirection: "column",
  backgroundColor: colors.panelBright,
  padding: 1,
});
inspectorText = new TextRenderable(renderer, {
  content: "Loading…",
  fg: colors.text,
  flexGrow: 1,
});
inspectorPanel.add(
  new TextRenderable(renderer, {
    content: "INSPECTOR",
    fg: colors.green,
    height: 2,
  }),
);
inspectorPanel.add(inspectorText);

statusText = new TextRenderable(renderer, {
  content: "Loading…",
  fg: colors.yellow,
  height: 2,
});
const footer = new TextRenderable(renderer, {
  content: "  q quit   r reload   ↑↓ select   home/end jump   PgUp/PgDn scroll",
  fg: colors.muted,
  height: 2,
});

body.add(diagramPanel);
body.add(inspectorPanel);
root.add(header);
root.add(body);
root.add(statusText);
root.add(footer);
renderer.root.add(root);

try {
  graph = await loadGraph();
  render();
} catch (error) {
  graph = { name: "Load error", scopes: [], nodes: [], edges: [] };
  diagramText.content = `Could not read ${inputPath}\n\n${error instanceof Error ? error.message : String(error)}`;
  inspectorText.content =
    "Pass a den-diagram JSON or Mermaid file as the first argument.";
  statusText.content = "Load failed";
}

renderer.keyInput.on("keypress", async (key) => {
  if (key.name === "q" || key.name === "escape") {
    renderer.destroy();
    return;
  }
  if (key.name === "r") {
    try {
      graph = await loadGraph();
      selectedIndex = 0;
      render();
    } catch {
      statusText.content = `Unable to reload ${inputPath}`;
    }
    return;
  }
  if (key.name === "down")
    selectedIndex = Math.min(graph.nodes.length - 1, selectedIndex + 1);
  else if (key.name === "up") selectedIndex = Math.max(0, selectedIndex - 1);
  else if (key.name === "home") selectedIndex = 0;
  else if (key.name === "end")
    selectedIndex = Math.max(0, graph.nodes.length - 1);
  else if (key.name === "pagedown") diagramScroll.scrollBy(1, "viewport");
  else if (key.name === "pageup") diagramScroll.scrollBy(-1, "viewport");
  else if (key.name === "right") diagramScroll.scrollBy({ x: 8, y: 0 });
  else if (key.name === "left") diagramScroll.scrollBy({ x: -8, y: 0 });
  else return;
  render();
});
