import { expect, test } from "bun:test";
import { layoutGraph } from "./layout";
import { normalizeGraph, parseMermaid } from "./model";

test("normalizes den-diagram Graph IR and preserves metadata", () => {
  const graph = normalizeGraph({
    name: "fixture",
    scopes: { root: { label: "Root", kind: "fleet" } },
    nodes: [{ id: "a", label: "Alpha", kind: "aspect", scope: "root" }],
    edges: [{ from: "a", to: "b", label: "includes" }],
  });

  expect(graph.name).toBe("fixture");
  expect(graph.scopes[0]?.label).toBe("Root");
  expect(graph.nodes.map((node) => node.id)).toEqual(["a", "b"]);
  expect(graph.edges[0]?.label).toBe("includes");
});

test("reads Mermaid emitted by den-diagram", () => {
  const graph = parseMermaid(`
    flowchart LR
      capture["Capture"] -- "trace entries" --> graph_["Graph"]
      graph_ --> filter["Filter"]
  `);

  expect(graph.nodes.find((node) => node.id === "capture")?.label).toBe(
    "Capture",
  );
  expect(graph.nodes.find((node) => node.id === "graph_")?.label).toBe("Graph");
  expect(graph.edges).toEqual([
    { from: "capture", to: "graph_", label: "trace entries" },
    { from: "graph_", to: "filter", label: undefined },
  ]);
});

test("lays out a graph as a terminal diagram", () => {
  const layout = layoutGraph(
    normalizeGraph({
      nodes: [
        { id: "a", label: "Alpha" },
        { id: "b", label: "Beta" },
      ],
      edges: [{ from: "a", to: "b" }],
    }),
    80,
  );

  expect(layout.lines.join("\n")).toContain("Alpha");
  expect(layout.lines.join("\n")).toContain("Beta");
  expect(layout.lines.join("\n")).toContain("▼");
});
