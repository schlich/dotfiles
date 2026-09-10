use chrono::Utc;
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, State};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workspace {
    pub name: String,
    pub root: String,
    #[serde(rename = "changeId", skip_serializing_if = "Option::is_none")]
    pub change_id: Option<String>,
    pub state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RepositorySnapshot {
    pub root: String,
    #[serde(rename = "jjVersion")]
    pub jj_version: String,
    pub status: String,
    pub log: String,
    pub workspaces: Vec<Workspace>,
    pub operations: String,
    #[serde(rename = "refreshedAt")]
    pub refreshed_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MutationResult {
    #[serde(rename = "beforeSnapshot")]
    pub before_snapshot: RepositorySnapshot,
    #[serde(rename = "executedCommand")]
    pub executed_command: String,
    #[serde(rename = "afterSnapshot")]
    pub after_snapshot: RepositorySnapshot,
    #[serde(rename = "jjOperationId", skip_serializing_if = "Option::is_none")]
    pub jj_operation_id: Option<String>,
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
struct NormalizedEvent {
    kind: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
}

/// Provider-neutral lifecycle boundary. Codex is the first implementation;
/// Pi and ACP can implement the same operations without reaching the JJ UI.
pub trait AgentProvider {
    fn start_session(&self, workspace_root: &str) -> Result<(), String>;
    fn send_turn(&self, workspace_root: &str, prompt: &str) -> Result<(), String>;
    fn cancel(&self) -> Result<(), String>;
    fn close(&self) -> Result<(), String>;
}

#[derive(Clone)]
pub struct StateStore {
    connection: Arc<Mutex<Connection>>,
}

impl StateStore {
    fn new() -> Result<Self, String> {
        let base = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| dirs::home_dir().map(|home| home.join(".local/state")))
            .or_else(dirs::data_local_dir)
            .unwrap_or_else(|| PathBuf::from("."))
            .join("jj-workbench");
        fs::create_dir_all(&base).map_err(|error| format!("create state directory: {error}"))?;
        let connection = Connection::open(base.join("state.sqlite3"))
            .map_err(|error| format!("open state database: {error}"))?;
        let store = Self {
            connection: Arc::new(Mutex::new(connection)),
        };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&self) -> Result<(), String> {
        let connection = self
            .connection
            .lock()
            .map_err(|_| "state database lock poisoned".to_string())?;
        connection
            .execute_batch(
                "
                CREATE TABLE IF NOT EXISTS repositories (
                    id TEXT PRIMARY KEY,
                    root TEXT NOT NULL UNIQUE,
                    jj_version TEXT,
                    policy_profile TEXT,
                    capabilities_json TEXT,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS workspaces (
                    id TEXT PRIMARY KEY,
                    repository_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    root TEXT NOT NULL,
                    working_copy_change_id TEXT,
                    state TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS agent_sessions (
                    id TEXT PRIMARY KEY,
                    provider TEXT NOT NULL,
                    workspace_id TEXT,
                    app_server_thread_id TEXT,
                    state TEXT NOT NULL,
                    goal TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS execution_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    timestamp TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS graph_links (
                    agent_session_id TEXT NOT NULL,
                    change_id TEXT,
                    workspace_id TEXT NOT NULL,
                    relationship TEXT NOT NULL,
                    PRIMARY KEY (agent_session_id, workspace_id, relationship)
                );
                ",
            )
            .map_err(|error| format!("migrate state database: {error}"))
    }

    fn record_event(&self, session_id: &str, event: &NormalizedEvent, raw: &Value) {
        let Ok(connection) = self.connection.lock() else {
            return;
        };
        let Ok(payload) = serde_json::to_string(&json!({ "event": event, "raw": raw })) else {
            return;
        };
        let _ = connection.execute(
            "INSERT INTO execution_events (session_id, sequence, kind, payload_json, timestamp)
             VALUES (?1, COALESCE((SELECT MAX(sequence) + 1 FROM execution_events WHERE session_id = ?1), 1), ?2, ?3, ?4)",
            params![session_id, &event.kind, payload, Utc::now().to_rfc3339()],
        );
    }
}

#[derive(Clone, Default)]
pub struct JjAdapter;

impl JjAdapter {
    fn validate_repository(&self, input: &str) -> Result<PathBuf, String> {
        let requested = PathBuf::from(input);
        let path = requested
            .canonicalize()
            .map_err(|error| format!("repository path is not readable: {error}"))?;
        if !path.is_dir() {
            return Err("repository path must be a directory".to_string());
        }
        let root = self.run_in(&path, &["root"])?;
        let detected = PathBuf::from(root.trim());
        if detected != path {
            return Err(format!("JJ root is {}, not {}", detected.display(), path.display()));
        }
        Ok(path)
    }

    fn run_in(&self, repo: &Path, args: &[&str]) -> Result<String, String> {
        let output = Command::new("jj")
            .current_dir(repo)
            .env("NO_COLOR", "1")
            .env("JJ_PAGER", "cat")
            .env("PAGER", "cat")
            .args(args)
            .output()
            .map_err(|error| format!("launch jj {}: {error}", args.join(" ")))?;
        let stdout = String::from_utf8_lossy(&output.stdout).trim_end().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim_end().to_string();
        if !output.status.success() {
            return Err(format!(
                "jj {} failed ({}):\n{}\n{}",
                args.join(" "),
                output.status,
                stdout,
                stderr
            ));
        }
        Ok(stdout)
    }

    fn discover(&self, input: &str) -> Result<String, String> {
        Ok(self.validate_repository(input)?.display().to_string())
    }

    fn snapshot(&self, input: &str) -> Result<RepositorySnapshot, String> {
        let repo = self.validate_repository(input)?;
        let jj_version = self.run_in(&repo, &["version"])?;
        let status = self.run_in(&repo, &["status"])?;
        let log = self.run_in(&repo, &["log", "--limit", "32"])?;
        let raw_workspaces = self.run_in(&repo, &["workspace", "list"])?;
        let operations = self.run_in(&repo, &["op", "log", "--limit", "20"])?;
        let workspaces = parse_workspaces(&repo, &raw_workspaces, &status);
        Ok(RepositorySnapshot {
            root: repo.display().to_string(),
            jj_version,
            status,
            log,
            workspaces,
            operations,
            refreshed_at: Utc::now().to_rfc3339(),
        })
    }

    fn describe(
        &self,
        input: &str,
        revision: &str,
        message: &str,
    ) -> Result<MutationResult, String> {
        let repo = self.validate_repository(input)?;
        let before_snapshot = self.snapshot(input)?;
        self.run_in(&repo, &["describe", "-r", revision, "-m", message])?;
        let after_snapshot = self.snapshot(input)?;
        let operation = self.run_in(&repo, &["op", "log", "--limit", "1", "-T", "id"])
            .ok()
            .and_then(|value| value.lines().find(|line| !line.trim().is_empty())
                .and_then(|line| line.split_whitespace().last())
                .map(str::to_string));
        Ok(MutationResult {
            before_snapshot,
            executed_command: format!("jj describe -r {revision} -m <description>"),
            after_snapshot,
            jj_operation_id: operation,
            warnings: vec!["The mutation is recorded in JJ's operation log.".to_string()],
        })
    }

    fn diff(&self, input: &str, revision: &str) -> Result<String, String> {
        let repo = self.validate_repository(input)?;
        self.run_in(&repo, &["diff", "-r", revision])
    }
}

fn parse_workspaces(repo: &Path, raw: &str, status: &str) -> Vec<Workspace> {
    let state = derive_jj_state(status);
    let mut workspaces = raw
        .lines()
        .filter_map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                return None;
            }
            let name = trimmed
                .split_whitespace()
                .next()
                .unwrap_or("workspace")
                .trim_end_matches(':')
                .to_string();
            let tokens = trimmed.split_whitespace().collect::<Vec<_>>();
            let root = tokens.get(1).map(|token| {
                if *token == "." { repo.display().to_string() } else { token.to_string() }
            }).unwrap_or_else(|| repo.display().to_string());
            let change_id = tokens.get(2).map(|token| token.to_string());
            let workspace_state = if trimmed.to_lowercase().contains("stale") {
                "stale".to_string()
            } else {
                state.clone()
            };
            Some(Workspace {
                name,
                root,
                change_id,
                state: workspace_state,
            })
        })
        .collect::<Vec<_>>();
    if workspaces.is_empty() {
        workspaces.push(Workspace {
            name: "default".to_string(),
            root: repo.display().to_string(),
            change_id: None,
            state,
        });
    }
    workspaces
}

fn derive_jj_state(status: &str) -> String {
    let lowercase = status.to_lowercase();
    if lowercase.contains("conflict") {
        "conflicted".to_string()
    } else if lowercase.contains("working copy changes") && !lowercase.contains("working copy is clean") {
        "modified".to_string()
    } else {
        "clean".to_string()
    }
}

pub struct CodexTransport {
    child: Mutex<Option<Child>>,
    stdin: Mutex<Option<ChildStdin>>,
    initialized: Mutex<bool>,
    initialize_ack: Arc<(Mutex<bool>, Condvar)>,
    thread_id: Arc<(Mutex<Option<String>>, Condvar)>,
}

impl Default for CodexTransport {
    fn default() -> Self {
        Self {
            child: Mutex::new(None),
            stdin: Mutex::new(None),
            initialized: Mutex::new(false),
            initialize_ack: Arc::new((Mutex::new(false), Condvar::new())),
            thread_id: Arc::new((Mutex::new(None), Condvar::new())),
        }
    }
}

impl CodexTransport {
    fn start(&self, app: AppHandle, store: StateStore) -> Result<(), String> {
        if self
            .child
            .lock()
            .map_err(|_| "Codex process lock poisoned".to_string())?
            .is_some()
        {
            return Ok(());
        }
        let mut child = Command::new(std::env::var("JJ_WORKBENCH_CODEX_BIN").unwrap_or_else(|_| "codex".to_string()))
            .args(["app-server", "--stdio"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|error| format!("launch Codex App Server: {error}"))?;
        let stdout = child.stdout.take().ok_or("Codex stdout was not available")?;
        let stderr = child.stderr.take().ok_or("Codex stderr was not available")?;
        let stdin = child.stdin.take().ok_or("Codex stdin was not available")?;
        *self.stdin.lock().map_err(|_| "Codex stdin lock poisoned".to_string())? = Some(stdin);
        *self.child.lock().map_err(|_| "Codex process lock poisoned".to_string())? = Some(child);

        let thread_id = Arc::clone(&self.thread_id);
        let initialize_ack = Arc::clone(&self.initialize_ack);
        let app_for_stdout = app.clone();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines().flatten() {
                let Ok(raw) = serde_json::from_str::<Value>(&line) else {
                    let event = NormalizedEvent { kind: "protocol_error".to_string(), title: "Invalid App Server message".to_string(), detail: Some(line.clone()) };
                    let _ = app_for_stdout.emit("codex:event", &event);
                    continue;
                };
                if raw.get("id") == Some(&json!(2)) {
                    if let Some(id) = raw.pointer("/result/thread/id").and_then(Value::as_str) {
                        if let Ok(mut current) = thread_id.0.lock() {
                            *current = Some(id.to_string());
                            thread_id.1.notify_all();
                        }
                    }
                }
                if raw.get("id") == Some(&json!(1)) {
                    if let Ok(mut acknowledged) = initialize_ack.0.lock() {
                        *acknowledged = true;
                        initialize_ack.1.notify_all();
                    }
                }
                let event = normalize_protocol_event(&raw);
                store.record_event("codex-local", &event, &raw);
                let _ = app_for_stdout.emit("codex:event", &event);
            }
            let event = NormalizedEvent { kind: "disconnected".to_string(), title: "Codex App Server disconnected".to_string(), detail: Some("The supervised process closed its output stream.".to_string()) };
            store.record_event("codex-local", &event, &json!({"kind":"disconnected"}));
            let _ = app_for_stdout.emit("codex:event", &event);
        });

        let app_for_stderr = app;
        thread::spawn(move || {
            for line in BufReader::new(stderr).lines().flatten() {
                let event = NormalizedEvent { kind: "process_log".to_string(), title: "Codex process log".to_string(), detail: Some(line) };
                let _ = app_for_stderr.emit("codex:event", &event);
            }
        });
        Ok(())
    }

    fn send(&self, message: Value) -> Result<(), String> {
        let mut stdin = self.stdin.lock().map_err(|_| "Codex stdin lock poisoned".to_string())?;
        let stdin = stdin.as_mut().ok_or("Codex App Server is not running")?;
        serde_json::to_writer(&mut *stdin, &message).map_err(|error| format!("encode App Server message: {error}"))?;
        stdin.write_all(b"\n").map_err(|error| format!("write App Server message: {error}"))?;
        stdin.flush().map_err(|error| format!("flush App Server message: {error}"))
    }

    fn start_turn(&self, repo: &str, prompt: &str) -> Result<(), String> {
        let mut initialized = self.initialized.lock().map_err(|_| "Codex state lock poisoned".to_string())?;
        if !*initialized {
            self.send(json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": { "name": "jj-workbench", "title": "JJ Workbench", "version": "0.1.0" }
                }
            }))?;
            let (lock, wake) = &*self.initialize_ack;
            let guard = lock.lock().map_err(|_| "Codex initialization lock poisoned".to_string())?;
            let (guard, _) = wake
                .wait_timeout_while(guard, Duration::from_secs(10), |acknowledged| !*acknowledged)
                .map_err(|_| "waiting for Codex initialization failed".to_string())?;
            if !*guard {
                return Err("Codex App Server did not acknowledge initialization within 10 seconds".to_string());
            }
            self.send(json!({ "jsonrpc": "2.0", "method": "initialized", "params": {} }))?;
            self.send(json!({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "thread/start",
                "params": {
                    "cwd": repo,
                    "approvalPolicy": "on-request",
                    "sandbox": "workspace-write"
                }
            }))?;
            let (lock, wake) = &*self.thread_id;
            let guard = lock.lock().map_err(|_| "Codex thread lock poisoned".to_string())?;
            let (guard, _) = wake
                .wait_timeout_while(guard, Duration::from_secs(10), |id| id.is_none())
                .map_err(|_| "waiting for Codex thread failed".to_string())?;
            if guard.is_none() {
                return Err("Codex App Server did not return a thread within 10 seconds".to_string());
            }
            *initialized = true;
        }
        let thread_id = self
            .thread_id
            .0
            .lock()
            .map_err(|_| "Codex thread lock poisoned".to_string())?
            .clone()
            .ok_or("Codex thread is not available")?;
        self.send(json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "turn/start",
            "params": {
                "threadId": thread_id,
                "input": [{ "type": "text", "text": prompt }]
            }
        }))
    }

    fn stop(&self) -> Result<(), String> {
        if let Some(mut child) = self.child.lock().map_err(|_| "Codex process lock poisoned".to_string())?.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *self.stdin.lock().map_err(|_| "Codex stdin lock poisoned".to_string())? = None;
        *self.initialized.lock().map_err(|_| "Codex state lock poisoned".to_string())? = false;
        *self.initialize_ack.0.lock().map_err(|_| "Codex initialization lock poisoned".to_string())? = false;
        *self.thread_id.0.lock().map_err(|_| "Codex thread lock poisoned".to_string())? = None;
        Ok(())
    }
}

impl AgentProvider for CodexTransport {
    fn start_session(&self, workspace_root: &str) -> Result<(), String> {
        let _ = workspace_root;
        Err("Codex transport requires a Tauri AppHandle; use codex_start".to_string())
    }

    fn send_turn(&self, workspace_root: &str, prompt: &str) -> Result<(), String> {
        self.start_turn(workspace_root, prompt)
    }

    fn cancel(&self) -> Result<(), String> {
        self.send(json!({ "jsonrpc": "2.0", "id": 4, "method": "turn/interrupt", "params": {} }))
    }

    fn close(&self) -> Result<(), String> {
        self.stop()
    }
}

fn normalize_protocol_event(raw: &Value) -> NormalizedEvent {
    let method = raw.get("method").and_then(Value::as_str).unwrap_or("response");
    let (kind, title) = match method {
        "turn/started" => ("turn_started", "Turn started"),
        "turn/completed" => ("turn_completed", "Turn completed"),
        "item/agentMessage/delta" => ("agent_message", "Agent message"),
        "item/started" => ("item_started", "Work item started"),
        "item/completed" => ("item_completed", "Work item completed"),
        value if value.contains("approval") || value.contains("permission") => ("approval_required", "Approval requested"),
        "response" => ("protocol_response", "App Server response"),
        _ => ("protocol_event", "App Server event"),
    };
    let detail = raw
        .get("params")
        .or_else(|| raw.get("result"))
        .map(|value| truncate(value.to_string(), 800));
    NormalizedEvent { kind: kind.to_string(), title: title.to_string(), detail }
}

fn truncate(value: String, max: usize) -> String {
    if value.chars().count() <= max {
        value
    } else {
        format!("{}…", value.chars().take(max).collect::<String>())
    }
}

pub struct AppState {
    jj: JjAdapter,
    codex: CodexTransport,
    store: StateStore,
    mutation_lock: Mutex<()>,
}

impl AppState {
    fn new() -> Result<Self, String> {
        Ok(Self { jj: JjAdapter, codex: CodexTransport::default(), store: StateStore::new()?, mutation_lock: Mutex::new(()) })
    }
}

#[tauri::command]
fn repository_discover(state: State<'_, AppState>, repo: String) -> Result<String, String> {
    state.jj.discover(&repo)
}

#[tauri::command]
fn jj_snapshot(state: State<'_, AppState>, repo: String) -> Result<RepositorySnapshot, String> {
    state.jj.snapshot(&repo)
}

#[tauri::command]
fn jj_diff(state: State<'_, AppState>, repo: String, revision: String) -> Result<String, String> {
    state.jj.diff(&repo, &revision)
}

#[tauri::command]
fn jj_describe(state: State<'_, AppState>, repo: String, revision: String, message: String) -> Result<MutationResult, String> {
    let _guard = state.mutation_lock.lock().map_err(|_| "JJ mutation lock poisoned".to_string())?;
    state.jj.describe(&repo, &revision, &message)
}

#[tauri::command]
fn codex_start(state: State<'_, AppState>, app: AppHandle) -> Result<(), String> {
    state.codex.start(app, state.store.clone())
}

#[tauri::command]
fn codex_stop(state: State<'_, AppState>) -> Result<(), String> {
    state.codex.stop()
}

#[tauri::command]
fn codex_start_turn(state: State<'_, AppState>, repo: String, prompt: String) -> Result<(), String> {
    state.codex.start_turn(&repo, &prompt)
}

pub fn run() {
    let state = AppState::new().expect("initialize JJ Workbench state");
    tauri::Builder::default()
        .manage(state)
        .invoke_handler(tauri::generate_handler![
            repository_discover,
            jj_snapshot,
            jj_diff,
            jj_describe,
            codex_start,
            codex_stop,
            codex_start_turn
        ])
        .run(tauri::generate_context!())
        .expect("error while running JJ Workbench");
}

#[cfg(test)]
mod tests {
    use super::{derive_jj_state, parse_workspaces};
    use std::path::Path;

    #[test]
    fn derives_conflicted_state() {
        assert_eq!(derive_jj_state("Working copy has conflicts"), "conflicted");
    }

    #[test]
    fn falls_back_to_default_workspace() {
        let workspaces = parse_workspaces(Path::new("/tmp/repo"), "", "The working copy is clean");
        assert_eq!(workspaces[0].name, "default");
        assert_eq!(workspaces[0].state, "clean");
    }
}
