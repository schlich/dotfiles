export type DiagramScope = {
  id: string;
  label?: string;
  name?: string;
  kind?: string;
  parent?: string | null;
};

export type DiagramNode = {
  id: string;
  label: string;
  description?: string;
  kind?: string;
  type?: string;
  scope?: string;
  host?: string;
  class?: string;
  [key: string]: unknown;
};

export type DiagramEdge = {
  from: string;
  to: string;
  label?: string;
  style?: string;
  [key: string]: unknown;
};

export type DiagramGraph = {
  name: string;
  scopes: DiagramScope[];
  nodes: DiagramNode[];
  edges: DiagramEdge[];
};

type UnknownRecord = Record<string, unknown>;

const asRecord = (value: unknown): UnknownRecord =>
  value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as UnknownRecord)
    : {};

const asString = (value: unknown, fallback: string): string =>
  typeof value === "string" && value.length > 0 ? value : fallback;

const records = (value: unknown): UnknownRecord[] => {
  if (Array.isArray(value)) return value.map(asRecord);
  return Object.entries(asRecord(value)).map(([id, item]) => ({
    id,
    ...asRecord(item),
  }));
};

const normalizeScopes = (value: unknown): DiagramScope[] =>
  records(value).map((scope, index) => ({
    id: asString(scope.id, `scope-${index + 1}`),
    label: typeof scope.label === "string" ? scope.label : undefined,
    name: typeof scope.name === "string" ? scope.name : undefined,
    kind: typeof scope.kind === "string" ? scope.kind : undefined,
    parent: typeof scope.parent === "string" ? scope.parent : null,
  }));

const normalizeNodes = (value: unknown): DiagramNode[] =>
  records(value).map((node, index) => ({
    ...node,
    id: asString(node.id, `node-${index + 1}`),
    label: asString(
      node.label ?? node.name,
      asString(node.id, `node-${index + 1}`),
    ),
    description:
      typeof node.description === "string" ? node.description : undefined,
    kind: typeof node.kind === "string" ? node.kind : undefined,
    type: typeof node.type === "string" ? node.type : undefined,
    scope: typeof node.scope === "string" ? node.scope : undefined,
    host: typeof node.host === "string" ? node.host : undefined,
    class: typeof node.class === "string" ? node.class : undefined,
  }));

const normalizeEdges = (value: unknown): DiagramEdge[] =>
  records(value)
    .map((edge) => ({
      ...edge,
      from: asString(edge.from ?? edge.source, ""),
      to: asString(edge.to ?? edge.target, ""),
      label: typeof edge.label === "string" ? edge.label : undefined,
      style: typeof edge.style === "string" ? edge.style : undefined,
    }))
    .filter((edge) => edge.from.length > 0 && edge.to.length > 0);

export function normalizeGraph(value: unknown): DiagramGraph {
  const root = asRecord(value);
  const graph = asRecord(root.graph);
  const source = Object.keys(graph).length > 0 ? graph : root;
  const nodes = normalizeNodes(source.nodes);
  const nodeIds = new Set(nodes.map((node) => node.id));

  for (const edge of normalizeEdges(source.edges)) {
    if (!nodeIds.has(edge.from))
      nodes.push({ id: edge.from, label: edge.from });
    if (!nodeIds.has(edge.to)) nodes.push({ id: edge.to, label: edge.to });
  }

  return {
    name: asString(source.name ?? root.name, "den diagram"),
    scopes: normalizeScopes(source.scopes),
    nodes,
    edges: normalizeEdges(source.edges),
  };
}

const nodeToken =
  /^([A-Za-z0-9_.:/@-]+)(?:\s*(?:\[\"([^\"]+)\"\]|\(\"([^\"]+)\"\)|\{\"([^\"]+)\"\}|\[([^\]]+)\]))?/;
const edgePatterns = [
  /^\s*([A-Za-z0-9_.:/@-]+).*?--\s*[\"']([^\"']+)[\"']\s*-->\s*([A-Za-z0-9_.:/@-]+)/,
  /^\s*([A-Za-z0-9_.:/@-]+).*?(?:-->|==>|-\.->)\s*\|([^|]+)\|\s*([A-Za-z0-9_.:/@-]+)/,
  /^\s*([A-Za-z0-9_.:/@-]+).*?(?:-->|==>|-\.->)\s*([A-Za-z0-9_.:/@-]+)/,
];

export function parseMermaid(source: string): DiagramGraph {
  const nodes = new Map<string, DiagramNode>();
  const edges: DiagramEdge[] = [];
  let name = "Mermaid diagram";

  const ensureNode = (id: string, label = id) => {
    if (!nodes.has(id)) nodes.set(id, { id, label: label.trim() });
  };

  for (const rawLine of source.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (
      !line ||
      line.startsWith("%%") ||
      line.startsWith("style ") ||
      line.startsWith("class ")
    )
      continue;
    if (/^(?:graph|flowchart)\s+/i.test(line)) {
      name = line.replace(/^(?:graph|flowchart)\s+/i, "").trim();
      continue;
    }

    const node = line.match(nodeToken);
    if (node && !line.startsWith("subgraph ")) {
      const [, id, square, round, curly, plain] = node;
      ensureNode(id, square ?? round ?? curly ?? plain ?? id);
    }

    let matchedEdge = false;
    for (const pattern of edgePatterns) {
      const edge = line.match(pattern);
      if (!edge) continue;
      const [, from, first, second] = edge;
      const hasLabel = pattern !== edgePatterns[2];
      const label = hasLabel ? first.trim() : undefined;
      const to = hasLabel ? second : first;
      const target = line.match(
        /(?:-->|==>|-\.->)\s*([A-Za-z0-9_.:\/@-]+)(?:\s*\[\"([^\"]+)\"\])?/,
      );
      ensureNode(from);
      ensureNode(to, target?.[2] ?? to);
      edges.push({ from, to, label });
      matchedEdge = true;
      break;
    }
    if (matchedEdge) continue;
  }

  return { name, scopes: [], nodes: [...nodes.values()], edges };
}
