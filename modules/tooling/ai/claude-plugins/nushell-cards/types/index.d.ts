// What the card knows of one followed job, keyed by its log's absolute path.
export type NushellJob = {
  log: string;
  // The last lines of the log, escape sequences and blank lines removed.
  tail: string[];
  // The latest OSC 7501 report, as `state · msg`.
  phase?: string;
  isDone: boolean;
  exitCode?: number;
  error?: string;
  // The Nushell that ran the job exited without recording an outcome.
  isLost?: boolean;
  startedAt: number;
};

declare module "claude-code" {
  interface PluginState {
    "nushell-cards": {
      jobs: StateFamily<NushellJob>;
      // Logs to follow, oldest first.
      logs: string[];
      // Whether a card shows its whole source, by tool_use_id.
      expanded: StateFamily<boolean>;
    };
  }
}
