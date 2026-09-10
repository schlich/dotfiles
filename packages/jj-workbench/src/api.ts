import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { MutationResult, RepositorySnapshot } from "./types";

export const isTauri = () =>
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

export async function snapshot(repo: string): Promise<RepositorySnapshot> {
  if (!isTauri()) return demoSnapshot(repo);
  return invoke<RepositorySnapshot>("jj_snapshot", { repo });
}

export async function discover(repo: string): Promise<string> {
  if (!isTauri()) return repo;
  return invoke<string>("repository_discover", { repo });
}

export async function diff(repo: string, revision = "@"): Promise<string> {
  if (!isTauri()) return "Demo mode: a read-only JJ diff will appear in the desktop shell.";
  return invoke<string>("jj_diff", { repo, revision });
}

export async function describe(
  repo: string,
  revision: string,
  message: string,
): Promise<MutationResult> {
  if (!isTauri()) {
    const beforeSnapshot = await snapshot(repo);
    return {
      beforeSnapshot,
      executedCommand: `jj describe -r ${revision} -m <description>`,
      afterSnapshot: beforeSnapshot,
      warnings: ["Demo mode does not mutate the repository."],
    };
  }
  return invoke<MutationResult>("jj_describe", { repo, revision, message });
}

export async function startCodex(): Promise<void> {
  if (isTauri()) await invoke("codex_start");
}

export async function stopCodex(): Promise<void> {
  if (isTauri()) await invoke("codex_stop");
}

export async function sendCodexTurn(repo: string, prompt: string): Promise<void> {
  if (isTauri()) await invoke("codex_start_turn", { repo, prompt });
}

export function onCodexEvent(
  callback: (event: { kind: string; title: string; detail?: string }) => void,
): Promise<UnlistenFn> {
  if (!isTauri()) return Promise.resolve(() => undefined);
  return listen("codex:event", (event) => callback(event.payload as never));
}

function demoSnapshot(repo: string): RepositorySnapshot {
  return {
    root: repo,
    jjVersion: "demo mode",
    status: "Working copy snapshot will appear when launched through Tauri.",
    log: "@  current working copy\n○  parent change\n◆  main",
    workspaces: [
      { name: "default", root: repo, changeId: "demo-current", state: "clean" },
    ],
    operations: "No operation history loaded yet.",
    refreshedAt: new Date().toISOString(),
  };
}
