export type AgentState =
  | "ready"
  | "starting"
  | "running"
  | "awaiting_approval"
  | "waiting_for_input"
  | "completed"
  | "failed"
  | "cancelled"
  | "disconnected";

export type JjState =
  | "clean"
  | "modified"
  | "conflicted"
  | "stale"
  | "rewritten"
  | "abandoned"
  | "unknown";

export interface Repository {
  id: string;
  root: string;
  jjVersion: string;
  policyProfile?: string;
  capabilities: string[];
}

export interface Workspace {
  id?: string;
  repositoryId?: string;
  name: string;
  root: string;
  changeId?: string;
  state: JjState;
}

export interface Change {
  id: string;
  repositoryId: string;
  workspaceId?: string;
  description: string;
  parents: string[];
  bookmarks: string[];
  files: string[];
  conflicts: boolean;
  state: JjState;
}

export interface AgentSession {
  id: string;
  provider: "codex" | "pi" | "acp";
  workspaceId: string;
  appServerThreadId?: string;
  state: AgentState;
  currentChangeId?: string;
  goal?: string;
  createdAt: string;
  updatedAt: string;
}

export interface ExecutionEvent {
  id: string;
  sessionId: string;
  sequence: number;
  kind: string;
  payload: unknown;
  timestamp: string;
}

export interface GraphLink {
  agentSessionId: string;
  changeId?: string;
  workspaceId: string;
  relationship: "started_in" | "currently_on" | "manually_linked";
}

export interface RepositorySnapshot {
  root: string;
  jjVersion: string;
  status: string;
  log: string;
  workspaces: Workspace[];
  operations: string;
  refreshedAt: string;
}

export interface TimelineItem {
  id: string;
  kind: string;
  title: string;
  detail?: string;
  tone: "neutral" | "accent" | "success" | "warning" | "danger";
  timestamp: string;
}

export interface MutationResult {
  beforeSnapshot: RepositorySnapshot;
  executedCommand: string;
  afterSnapshot: RepositorySnapshot;
  jjOperationId?: string;
  warnings: string[];
}
