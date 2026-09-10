import type { AgentState, TimelineItem } from "./types";

export type ProviderId = "codex" | "pi" | "acp";

export interface AgentSession {
  id: string;
  provider: ProviderId;
  workspaceId: string;
  appServerThreadId?: string;
  state: AgentState;
  currentChangeId?: string;
  goal?: string;
  createdAt: string;
  updatedAt: string;
}

export interface AgentProvider {
  discover(): Promise<{ id: ProviderId; version?: string; available: boolean }>;
  startSession(workspaceRoot: string, goal?: string): Promise<AgentSession>;
  resumeSession(sessionId: string): Promise<AgentSession>;
  sendTurn(sessionId: string, prompt: string): Promise<void>;
  cancel(sessionId: string): Promise<void>;
  respondToApproval(sessionId: string, approvalId: string, approved: boolean): Promise<void>;
  subscribe(sessionId: string, listener: (item: TimelineItem) => void): () => void;
  close(): Promise<void>;
}
