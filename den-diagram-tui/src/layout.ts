import type { DiagramEdge, DiagramGraph, DiagramNode } from "./model";

export type Layout = {
  lines: string[];
  width: number;
  height: number;
  nodeIds: string[];
};

type Position = { x: number; y: number; width: number; rank: number };

const BOX_HEIGHT = 3;
const RANK_GAP = 3;
const NODE_GAP = 5;
const MIN_NODE_WIDTH = 14;
const MAX_NODE_WIDTH = 28;

function shorten(text: string, width: number): string {
  const value = text.replace(/\s+/g, " ").trim();
  if (value.length <= width) return value;
  return `${value.slice(0, Math.max(1, width - 1))}…`;
}

function rankNodes(graph: DiagramGraph): Map<string, number> {
  const ranks = new Map(graph.nodes.map((node) => [node.id, 0]));
  const incoming = new Map<string, DiagramEdge[]>();
  for (const edge of graph.edges) {
    const list = incoming.get(edge.to) ?? [];
    list.push(edge);
    incoming.set(edge.to, list);
  }

  // A bounded relaxation keeps cyclic or imperfect input renderable.
  for (let pass = 0; pass < graph.nodes.length; pass += 1) {
    let changed = false;
    for (const node of graph.nodes) {
      const next = Math.max(
        0,
        ...(incoming.get(node.id) ?? []).map(
          (edge) => (ranks.get(edge.from) ?? 0) + 1,
        ),
      );
      if (next > (ranks.get(node.id) ?? 0)) {
        ranks.set(node.id, next);
        changed = true;
      }
    }
    if (!changed) break;
  }
  return ranks;
}

class Canvas {
  private readonly cells: string[][];

  constructor(
    readonly width: number,
    readonly height: number,
  ) {
    this.cells = Array.from({ length: height }, () =>
      Array.from({ length: width }, () => " "),
    );
  }

  put(x: number, y: number, value: string): void {
    if (y < 0 || y >= this.height) return;
    for (let index = 0; index < value.length; index += 1) {
      const targetX = x + index;
      if (targetX >= 0 && targetX < this.width)
        this.cells[y][targetX] = value[index];
    }
  }

  line(x1: number, y1: number, x2: number, y2: number): void {
    if (x1 === x2) {
      const start = Math.min(y1, y2);
      const end = Math.max(y1, y2);
      for (let y = start; y <= end; y += 1) this.put(x1, y, "│");
      return;
    }
    if (y1 === y2) {
      const start = Math.min(x1, x2);
      const end = Math.max(x1, x2);
      for (let x = start; x <= end; x += 1) this.put(x, y1, "─");
      return;
    }
    this.line(x1, y1, x1, y2);
    this.line(Math.min(x1, x2), y2, Math.max(x1, x2), y2);
  }

  toLines(): string[] {
    return this.cells.map((row) => row.join("").trimEnd());
  }
}

function drawEdge(
  canvas: Canvas,
  edge: DiagramEdge,
  positions: Map<string, Position>,
): void {
  const from = positions.get(edge.from);
  const to = positions.get(edge.to);
  if (!from || !to) return;

  if (from.rank === to.rank) {
    const start = from.x + from.width;
    const end = to.x - 1;
    canvas.line(start, from.y + 1, end, to.y + 1);
    canvas.put(end, to.y + 1, "▶");
    return;
  }

  const startX = from.x + Math.floor(from.width / 2);
  const endX = to.x + Math.floor(to.width / 2);
  const startY = from.y + BOX_HEIGHT;
  const endY = to.y - 1;
  const midY = Math.floor((startY + endY) / 2);
  canvas.line(startX, startY, startX, midY);
  canvas.line(startX, midY, endX, midY);
  canvas.line(endX, midY, endX, endY);
  canvas.put(endX, endY, "▼");
}

function drawNode(canvas: Canvas, node: DiagramNode, position: Position): void {
  const { x, y, width } = position;
  const label = shorten(node.label, width - 4);
  const leftPadding = Math.max(0, Math.floor((width - 2 - label.length) / 2));
  const centeredLabel = label
    .padStart(leftPadding + label.length)
    .padEnd(width - 2);
  canvas.put(x, y, `┌${"─".repeat(width - 2)}┐`);
  canvas.put(x, y + 1, `│${centeredLabel}│`);
  canvas.put(x, y + 2, `└${"─".repeat(width - 2)}┘`);
}

export function layoutGraph(
  graph: DiagramGraph,
  terminalWidth: number,
): Layout {
  const nodeWidth = Math.max(
    MIN_NODE_WIDTH,
    Math.min(MAX_NODE_WIDTH, terminalWidth - 4),
  );
  const ranks = rankNodes(graph);
  const grouped = new Map<number, DiagramNode[]>();
  for (const node of graph.nodes) {
    const rank = ranks.get(node.id) ?? 0;
    const list = grouped.get(rank) ?? [];
    list.push(node);
    grouped.set(rank, list);
  }

  const orderedRanks = [...grouped.keys()].sort((left, right) => left - right);
  const positions = new Map<string, Position>();
  let canvasWidth = 0;
  for (const rank of orderedRanks) {
    const row = grouped.get(rank) ?? [];
    row.sort((left, right) => left.label.localeCompare(right.label));
    row.forEach((node, index) => {
      const x = index * (nodeWidth + NODE_GAP);
      positions.set(node.id, {
        x,
        y: orderedRanks.indexOf(rank) * (BOX_HEIGHT + RANK_GAP),
        width: nodeWidth,
        rank,
      });
      canvasWidth = Math.max(canvasWidth, x + nodeWidth);
    });
  }

  const canvasHeight = Math.max(
    1,
    orderedRanks.length * (BOX_HEIGHT + RANK_GAP) - RANK_GAP,
  );
  const canvas = new Canvas(canvasWidth, canvasHeight);
  for (const edge of graph.edges) drawEdge(canvas, edge, positions);
  for (const node of graph.nodes) {
    const position = positions.get(node.id);
    if (position) drawNode(canvas, node, position);
  }

  return {
    lines: canvas.toLines(),
    width: canvasWidth,
    height: canvasHeight,
    nodeIds: graph.nodes.map((node) => node.id),
  };
}
