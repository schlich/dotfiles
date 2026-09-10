import { useEffect, useMemo, useState } from "react";
import {
  Activity,
  Bot,
  ChevronRight,
  CircleDot,
  GitBranch,
  GitCommitHorizontal,
  Layers3,
  Play,
  RefreshCw,
  Send,
  Settings2,
  ShieldCheck,
  Terminal,
  Undo2,
  X,
} from "lucide-react";
import {
  discover,
  diff,
  describe,
  onCodexEvent,
  sendCodexTurn,
  snapshot,
  startCodex,
  stopCodex,
} from "./api";
import type { RepositorySnapshot, TimelineItem } from "./types";

const DEFAULT_REPO = "/home/schlich/dotfiles";

const initialTimeline: TimelineItem[] = [
  {
    id: "boot",
    kind: "system",
    title: "Workbench ready",
    detail: "JJ is the source of truth for changes, workspaces, and recovery.",
    tone: "accent",
    timestamp: "now",
  },
];

function App() {
  const [repoInput, setRepoInput] = useState(DEFAULT_REPO);
  const [repo, setRepo] = useState(DEFAULT_REPO);
  const [data, setData] = useState<RepositorySnapshot | null>(null);
  const [timeline, setTimeline] = useState(initialTimeline);
  const [prompt, setPrompt] = useState("");
  const [description, setDescription] = useState("");
  const [busy, setBusy] = useState(false);
  const [codexRunning, setCodexRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [diffText, setDiffText] = useState("");

  const loadSnapshot = async (path = repo) => {
    setBusy(true);
    setError(null);
    try {
      const resolved = await discover(path);
      setRepo(resolved);
      setRepoInput(resolved);
      setData(await snapshot(resolved));
      setDiffText(await diff(resolved));
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    void loadSnapshot();
    const unlisten = onCodexEvent((event) => {
      setTimeline((items) => [
        ...items,
        {
          id: crypto.randomUUID(),
          kind: event.kind,
          title: event.title,
          detail: event.detail,
          tone: event.kind.includes("error") ? "danger" : "neutral",
          timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }),
        },
      ]);
    });
    return () => {
      void unlisten.then((dispose) => dispose());
      void stopCodex();
    };
  }, []);

  const workspaces = data?.workspaces ?? [];
  const logLines = useMemo(() => (data?.log ?? "").split("\n").filter(Boolean), [data]);

  const addTimeline = (item: Omit<TimelineItem, "id" | "timestamp">) => {
    setTimeline((items) => [
      ...items,
      { ...item, id: crypto.randomUUID(), timestamp: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) },
    ]);
  };

  const handleStartAgent = async () => {
    if (!prompt.trim()) return;
    try {
      setError(null);
      await startCodex();
      setCodexRunning(true);
      await sendCodexTurn(repo, prompt.trim());
      addTimeline({ kind: "turn", title: "Turn started", detail: prompt.trim(), tone: "accent" });
      setPrompt("");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
      addTimeline({ kind: "error", title: "Agent could not start", detail: String(reason), tone: "danger" });
    }
  };

  const handleDescribe = async () => {
    if (!description.trim()) return;
    if (!window.confirm("Describe the current JJ change? This writes a new description.")) return;
    try {
      setBusy(true);
      const result = await describe(repo, "@", description.trim());
      setData(result.afterSnapshot);
      setDiffText(await diff(repo));
      addTimeline({ kind: "jj", title: "Working copy described", detail: result.executedCommand, tone: "success" });
      setDescription("");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setBusy(false);
    }
  };

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand-mark"><GitBranch size={18} /></div>
        <div>
          <div className="eyebrow">JJ-FIRST AGENT WORKBENCH</div>
          <div className="brand-title">Codex Workbench</div>
        </div>
        <div className="topbar-spacer" />
        <div className="connection-state"><span className="pulse" /> local workspace</div>
        <button className="icon-button" title="Settings"><Settings2 size={17} /></button>
      </header>

      <section className="workspace-bar">
        <div className="repo-label"><Layers3 size={16} /><span>Repository</span></div>
        <input value={repoInput} onChange={(event) => setRepoInput(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void loadSnapshot(repoInput); }} />
        <button className="secondary-button" onClick={() => void loadSnapshot(repoInput)} disabled={busy}><RefreshCw size={15} className={busy ? "spin" : ""} /> Refresh</button>
        <div className="workspace-meta"><ShieldCheck size={15} /> read-only by default</div>
      </section>

      <div className="content-grid">
        <aside className="sidebar panel">
          <div className="panel-heading"><span>WORKSPACES</span><span className="count-badge">{workspaces.length}</span></div>
          <div className="workspace-list">
            {workspaces.map((workspace) => (
              <button className="workspace-row" key={workspace.name} onClick={() => addTimeline({ kind: "workspace", title: `Selected ${workspace.name}`, detail: workspace.root, tone: "accent" })}>
                <CircleDot size={15} className={`state-icon ${workspace.state}`} />
                <span className="workspace-copy"><strong>{workspace.name}</strong><small>{workspace.changeId ?? "working copy"}</small></span>
                <ChevronRight size={15} className="muted-icon" />
              </button>
            ))}
            {!workspaces.length && <div className="empty-copy">No JJ workspaces found.</div>}
          </div>

          <div className="sidebar-divider" />
          <div className="panel-heading"><span>AGENT SESSIONS</span><span className={`status-label ${codexRunning ? "live" : ""}`}>{codexRunning ? "LIVE" : "IDLE"}</span></div>
          <div className="agent-card selected-card">
            <div className="agent-icon"><Bot size={16} /></div>
            <div className="workspace-copy"><strong>Codex · local</strong><small>{codexRunning ? "running in default" : "no active session"}</small></div>
            <span className={`agent-dot ${codexRunning ? "running" : ""}`} />
          </div>
          <div className="sidebar-footer"><Terminal size={14} /> App Server transport pending connection</div>
        </aside>

        <section className="main-column">
          <div className="hero-row">
            <div><div className="eyebrow">WORKBENCH</div><h1>Change graph</h1><p>See agent activity and JJ evolution in one place.</p></div>
            <div className="hero-stats"><div><strong>{logLines.length || 0}</strong><span>visible changes</span></div><div><strong>{timeline.length}</strong><span>events</span></div></div>
          </div>

          <div className="graph panel">
            <div className="panel-toolbar"><div className="toolbar-title"><GitCommitHorizontal size={16} /> JJ log</div><span className="toolbar-context">default workspace · refreshed {data ? new Date(data.refreshedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "—"}</span></div>
            <div className="graph-body">
              {logLines.length ? logLines.map((line, index) => <div className={`graph-line ${index === 0 ? "current" : ""}`} key={`${line}-${index}`}><span className="graph-node" /><code>{line}</code></div>) : <div className="empty-copy">Open a JJ repository to render its change graph.</div>}
            </div>
          </div>

          <div className="lower-grid">
            <div className="timeline panel">
              <div className="panel-toolbar"><div className="toolbar-title"><Activity size={16} /> Execution timeline</div><span className="toolbar-context">live projection</span></div>
              <div className="timeline-body">
                {timeline.slice(-8).map((item) => <div className="timeline-row" key={item.id}><div className={`timeline-marker ${item.tone}`} /><div className="timeline-copy"><div><strong>{item.title}</strong><time>{item.timestamp}</time></div>{item.detail && <p>{item.detail}</p>}<span className="event-kind">{item.kind}</span></div></div>)}
              </div>
            </div>

            <div className="inspector panel">
              <div className="panel-toolbar"><div className="toolbar-title"><GitCommitHorizontal size={16} /> Current change</div><span className="toolbar-context">@</span></div>
              <div className="inspector-body">
                <div className="change-id">{data?.workspaces[0]?.changeId ?? "working-copy"}</div>
                <div className="change-title">{data?.status.split("\n")[0] || "No status loaded"}</div>
                <div className="inspector-section"><span className="section-label">DESCRIBE WORKING COPY</span><div className="describe-row"><input value={description} onChange={(event) => setDescription(event.target.value)} placeholder="What changed?" onKeyDown={(event) => { if (event.key === "Enter") void handleDescribe(); }} /><button className="small-action" onClick={() => void handleDescribe()} disabled={!description.trim() || busy}><Send size={14} /></button></div></div>
                <div className="inspector-section"><span className="section-label">STATUS</span><pre className="status-pre">{data?.status || "Loading JJ status…"}</pre></div>
                <div className="inspector-section"><span className="section-label">READ-ONLY DIFF</span><pre className="status-pre diff-pre">{diffText || "No diff in the working copy."}</pre></div>
                <div className="inspector-section"><span className="section-label">OPERATION LOG</span><pre className="status-pre">{data?.operations || "No operation history loaded."}</pre></div>
              </div>
            </div>
          </div>

          <div className="composer panel"><div className="composer-icon"><Bot size={17} /></div><input value={prompt} onChange={(event) => setPrompt(event.target.value)} placeholder="Ask Codex to work in this JJ workspace…" onKeyDown={(event) => { if (event.key === "Enter") void handleStartAgent(); }} /><button className="primary-button" onClick={() => void handleStartAgent()} disabled={!prompt.trim()}><Play size={14} /> Start turn</button></div>
          {error && <div className="error-banner"><X size={16} /><span>{error}</span><button onClick={() => setError(null)}><X size={14} /></button></div>}
        </section>
      </div>

      <footer className="statusbar"><span><span className="status-dot ok" /> JJ adapter online</span><span>{data?.jjVersion ?? "detecting JJ"}</span><span><Undo2 size={13} /> operations recoverable</span></footer>
    </main>
  );
}

export default App;
