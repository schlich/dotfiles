// OpenCode TUI plugin: live views of the agentic workflow around a session —
// its version control (JJ or Git), CI on the pushed commit (GitHub Actions and
// nixbot), background jobs (job-log and ci jobs on cross.stream, Claude Code's
// background tasks, OpenCode's own shells), luvus tasks, and the host's staged
// NixOS switch. A sidebar section and a home-footer item summarize it; the
// workflow panel lists every row. Wherever the panel takes keys, its bottom
// line names the mode and every key that works in it.
import type { LocationRef } from "@opencode/client";
import { Plugin } from "@opencode/plugin/tui";
import type { PanelInput, Route } from "@opencode/plugin/tui/context";
import { useTerminalDimensions } from "@opentui/solid";
import {
  createEffect,
  createMemo,
  createSignal,
  For,
  Index,
  on,
  onCleanup,
  Show,
} from "solid-js";
import {
  copyText,
  createHubs,
  openUrl,
  type HostHub,
  type Hubs,
  type RepoHub,
  type Section,
} from "./collect";
import * as M from "./model";

type Context = Plugin.Context;
type Theme = Context["theme"];
type SectionID = "vcs" | "ci" | "jobs" | "tasks" | "deploy";

const PANEL = "workflow";
const OPEN = "workflow.open";
const SECTIONS: readonly SectionID[] = ["vcs", "ci", "jobs", "tasks", "deploy"];
const TITLES: Readonly<Record<SectionID, string>> = {
  vcs: "VCS",
  ci: "CI",
  jobs: "Jobs",
  tasks: "Tasks",
  deploy: "Deploy",
};
// OpenCode events after which a repository in view may have moved.
const ACTIVITY = /^(session\.execution\.|shell\.exited|vcs\.)/;
// Below this width the panel names only the current section.
const NARROW = 52;

/** A request, from a sidebar row, to show one section; `at` makes a repeat a change. */
interface Request {
  readonly section: SectionID;
  readonly at: number;
}

interface View {
  readonly summary?: M.Summary;
  readonly rows: readonly M.Row[];
  /** Nothing to show here, such as Tasks without luvus or Deploy off NixOS. */
  readonly hidden: boolean;
  readonly updated?: number;
}

function toneColor(theme: Theme, tone: M.Tone) {
  switch (tone) {
    case "ok":
      return theme.text.feedback.success.base;
    case "warn":
      return theme.text.feedback.warning.base;
    case "error":
      return theme.text.feedback.error.base;
    case "busy":
      return theme.text.feedback.info.base;
    default:
      return theme.text.muted;
  }
}

function rowsOf<T>(
  section: Section<T> | undefined,
  rows: (data: T) => readonly M.Row[],
  empty: string,
): M.Row[] {
  if (
    section === undefined ||
    (section.data === undefined &&
      section.error === undefined &&
      section.loading)
  )
    return [{ key: "loading", tone: "idle", label: "loading…" }];
  const out: M.Row[] = [];
  if (section.error)
    out.push({
      key: "error",
      tone: "error",
      label: section.error,
      copy: section.error,
    });
  if (section.data !== undefined) out.push(...rows(section.data));
  if (out.length === 0) out.push({ key: "empty", tone: "idle", label: empty });
  return out;
}

function summaryOf<T>(
  section: Section<T> | undefined,
  summarize: (data: T) => M.Summary,
): M.Summary | undefined {
  if (section === undefined) return undefined;
  if (section.data === undefined) {
    if (section.error) return { tone: "error", text: section.error };
    return section.loading ? { tone: "idle", text: "loading…" } : undefined;
  }
  const summary = summarize(section.data);
  // Data that could not refresh is still shown, flagged.
  return section.error
    ? { tone: M.worst([summary.tone, "warn"]), text: summary.text }
    : summary;
}

function buildViews(
  repo: RepoHub | undefined,
  host: HostHub,
  shells: readonly M.Job[],
  now: number,
): Readonly<Record<SectionID, View>> {
  const vcs = repo?.vcs();
  const ci = repo?.ci();
  const tasks = repo?.tasks();
  const deploy = host.deploy();
  const xs = host.jobs();
  const claude = host.claude();
  const waiting = xs.loading && claude.loading && shells.length === 0;
  const jobs: Section<readonly M.Job[]> = {
    data: waiting
      ? undefined
      : [...(xs.data ?? []), ...(claude.data ?? []), ...shells],
    error: xs.error,
    loading: waiting,
    updated: Math.max(xs.updated ?? 0, claude.updated ?? 0) || undefined,
  };
  return {
    vcs: {
      summary: summaryOf(vcs, M.summarizeVcs),
      rows: rowsOf(vcs, M.vcsRows, "no repository"),
      hidden: false,
      updated: vcs?.updated,
    },
    ci: {
      summary: summaryOf(ci, (data) =>
        data.checks.length > 0
          ? M.summarizeChecks(data.checks)
          : { tone: "idle", text: data.target },
      ),
      rows: rowsOf(ci, (data) => M.ciRows(data, now), "no CI"),
      hidden: repo === undefined,
      updated: ci?.updated,
    },
    jobs: {
      summary: summaryOf(jobs, (data) => M.summarizeJobs(data, now)),
      rows: rowsOf(
        jobs,
        (data) => M.jobRows(data, now),
        "no background jobs in the last 30 minutes",
      ),
      hidden: false,
      updated: jobs.updated,
    },
    tasks: {
      summary: summaryOf(tasks, M.summarizeTasks),
      rows: rowsOf(
        tasks,
        M.taskRows,
        "no open luvus tasks for this repository",
      ),
      hidden:
        tasks === undefined ||
        (!tasks.loading &&
          tasks.data === undefined &&
          tasks.error === undefined),
      updated: tasks?.updated,
    },
    deploy: {
      summary: summaryOf(deploy, (data) => M.summarizeDeploy(data, now)),
      rows: rowsOf(
        deploy,
        (data) => M.deployRows(data, now),
        "no switches recorded",
      ),
      hidden:
        !deploy.loading &&
        deploy.data === undefined &&
        deploy.error === undefined,
      updated: deploy.updated,
    },
  };
}

/** The sections worth a line outside the panel: always VCS and CI, the rest when they need attention or report. */
function overview(
  views: Readonly<Record<SectionID, View>>,
): { readonly section: SectionID; readonly summary: M.Summary }[] {
  return SECTIONS.flatMap((section) => {
    const view = views[section];
    if (view.hidden || !view.summary) return [];
    if (view.summary.tone === "idle" && section !== "vcs" && section !== "ci")
      return [];
    return [{ section, summary: view.summary }];
  });
}

function useClock(interval: number) {
  const [now, setNow] = createSignal(Date.now());
  const timer = setInterval(() => setNow(Date.now()), interval);
  onCleanup(() => clearInterval(timer));
  return now;
}

function useRepo(hubs: Hubs, directory: () => string | undefined) {
  const [hub, setHub] = createSignal<RepoHub>();
  createEffect(
    on(directory, (value) => {
      if (value === undefined) return void setHub(undefined);
      const lease = hubs.repo(value);
      setHub(() => lease.hub);
      onCleanup(lease.release);
    }),
  );
  return hub;
}

function useHost(hubs: Hubs) {
  const lease = hubs.host();
  onCleanup(lease.release);
  return lease.hub;
}

/** OpenCode's own shells at a location, as jobs. */
function useShells(context: Context, location: () => LocationRef | undefined) {
  createEffect(
    on(
      location,
      (value) => void context.data.shell.sync(value).catch(() => undefined),
    ),
  );
  return createMemo(() =>
    (context.data.shell.list(location()) ?? []).map(M.shellJob),
  );
}

function SidebarSection(props: {
  context: Context;
  hubs: Hubs;
  sessionID: string;
  open: (section?: SectionID) => void;
}) {
  const theme = () => props.context.theme;
  const session = createMemo(() =>
    props.context.data.session.get(props.sessionID),
  );
  const location = createMemo(
    () => session()?.location ?? props.context.location,
  );
  const repo = useRepo(props.hubs, () => location()?.directory);
  const host = useHost(props.hubs);
  const now = useClock(15_000);
  const shells = useShells(props.context, location);
  const lines = createMemo(() =>
    overview(buildViews(repo(), host, shells(), now())),
  );
  const shortcut = () => props.context.keymap.shortcuts(OPEN)[0];

  return (
    <box>
      <box
        flexDirection="row"
        justifyContent="space-between"
        gap={1}
        onMouseUp={() => props.open()}
      >
        <text fg={theme().text.base}>
          <b>Workflow</b>
        </text>
        <Show when={shortcut()}>
          {(key) => (
            <text fg={theme().text.muted} wrapMode="none" flexShrink={0}>
              {key()}
            </text>
          )}
        </Show>
      </box>
      <For each={lines()}>
        {(line) => (
          <box
            flexDirection="row"
            gap={1}
            minWidth={0}
            onMouseUp={() => props.open(line.section)}
          >
            <text flexShrink={0} fg={toneColor(theme(), line.summary.tone)}>
              {M.glyph[line.summary.tone]}
            </text>
            <text flexShrink={0} fg={theme().text.muted} wrapMode="none">
              {TITLES[line.section]}
            </text>
            <text
              fg={theme().text.base}
              wrapMode="none"
              truncate
              flexGrow={1}
              flexShrink={1}
              minWidth={0}
            >
              {line.summary.text}
            </text>
          </box>
        )}
      </For>
    </box>
  );
}

function HomeStatus(props: { context: Context; hubs: Hubs; open: () => void }) {
  const theme = () => props.context.theme;
  const dimensions = useTerminalDimensions();
  const location = () => props.context.location;
  const repo = useRepo(props.hubs, () => location()?.directory);
  const host = useHost(props.hubs);
  const now = useClock(15_000);
  const shells = useShells(props.context, location);
  const parts = createMemo(() =>
    overview(buildViews(repo(), host, shells(), now())).map(
      ({ section, summary }) => ({
        tone: summary.tone,
        text:
          section === "vcs"
            ? summary.text.slice(0, 28)
            : `${TITLES[section]} ${M.glyph[summary.tone]}`,
      }),
    ),
  );
  const tone = createMemo(() => M.worst(parts().map((part) => part.tone)));
  const shortcut = () => props.context.keymap.shortcuts(OPEN)[0];

  return (
    <Show when={parts().length > 0}>
      <box
        flexDirection="row"
        gap={1}
        flexShrink={0}
        onMouseUp={() => props.open()}
      >
        <text fg={theme().text.base} wrapMode="none">
          <span style={{ fg: toneColor(theme(), tone()) }}>◆ </span>
          {parts()
            .map((part) => part.text)
            .join(" · ")}
        </text>
        <Show when={dimensions().width >= 100}>
          <text fg={theme().text.muted} wrapMode="none">
            {shortcut() ?? "/workflow"}
          </text>
        </Show>
      </box>
    </Show>
  );
}

interface Key {
  readonly bind: string;
  readonly title: string;
  /** Shown in the hint line as `hint label`; a key without one shares another's, as k shares j/k. */
  readonly hint?: string;
  readonly label?: string;
  readonly enabled?: () => boolean;
  readonly run: () => void;
}

function keepVisible(scroll: unknown, index: number) {
  const box = scroll as
    | {
        scrollTop?: number;
        height?: number;
        viewport?: { height?: number };
        scrollTo?: (y: number) => void;
      }
    | undefined;
  if (typeof box?.scrollTo !== "function") return;
  const top = typeof box.scrollTop === "number" ? box.scrollTop : 0;
  const height = box.viewport?.height ?? box.height ?? 0;
  if (index < top) box.scrollTo(index);
  else if (height > 0 && index >= top + height)
    box.scrollTo(index - height + 1);
}

function WorkflowView(props: {
  context: Context;
  hubs: Hubs;
  location: () => LocationRef | undefined;
  panel?: PanelInput;
  request: () => Request | undefined;
  onClose: () => void;
}) {
  const theme = () => props.context.theme;
  const dimensions = useTerminalDimensions();
  const repo = useRepo(props.hubs, () => props.location()?.directory);
  const host = useHost(props.hubs);
  const now = useClock(1_000);
  const shells = useShells(props.context, props.location);
  const views = createMemo(() => buildViews(repo(), host, shells(), now()));
  const visible = createMemo(() =>
    SECTIONS.filter((id) => !views()[id].hidden),
  );

  // NORMAL moves through a section's rows; DETAIL reads one row. Esc goes back
  // one step: from DETAIL to NORMAL, and from NORMAL out of the view.
  const [mode, setMode] = createSignal<"normal" | "detail">("normal");
  const [chosen, setChosen] = createSignal<SectionID>(
    props.request()?.section ?? "vcs",
  );
  createEffect(
    on(
      props.request,
      (request) => {
        if (!request) return;
        setChosen(request.section);
        setMode("normal");
      },
      { defer: true },
    ),
  );
  const section = createMemo(() =>
    visible().includes(chosen()) ? chosen() : (visible()[0] ?? "vcs"),
  );
  const [cursors, setCursors] = createSignal<
    Partial<Record<SectionID, number>>
  >({});
  const rows = createMemo(() => views()[section()].rows);
  const index = createMemo(() =>
    Math.min(
      Math.max(cursors()[section()] ?? 0, 0),
      Math.max(rows().length - 1, 0),
    ),
  );
  const selected = createMemo<M.Row | undefined>(() => rows()[index()]);

  const docked = () => props.panel?.presentation === "panel";
  const focused = () =>
    props.panel === undefined ||
    props.panel.presentation === "fullscreen" ||
    props.panel.focused;
  const width = () => props.panel?.width ?? dimensions().width;
  const surface = () =>
    docked() ? theme().background.raised.base : theme().background.base;
  const highlight = () =>
    docked() ? theme().background.raised.high : theme().background.raised.base;
  let list: unknown;
  let detail: unknown;

  const select = (next: number) => {
    const target = Math.min(Math.max(next, 0), Math.max(rows().length - 1, 0));
    setCursors((current) => ({ ...current, [section()]: target }));
    keepVisible(list, target);
  };
  const show = (id: SectionID | undefined) => {
    if (id === undefined) return;
    setChosen(id);
    setMode("normal");
  };
  const cycle = (offset: number) => {
    const ids = visible();
    show(ids[(ids.indexOf(section()) + offset + ids.length) % ids.length]);
  };
  const refresh = (all: boolean) => {
    const target = section();
    if (all) {
      repo()?.refresh();
      host.refresh();
    } else if (target === "vcs" || target === "ci" || target === "tasks")
      repo()?.refresh(target);
    else host.refresh(target);
  };
  const copy = async (value: string) => {
    const copied = await copyText(props.context.renderer, value);
    props.context.ui.toast.show({
      variant: copied ? "success" : "warning",
      title: copied ? "Copied" : "Nothing copied",
      message: copied ? value.slice(0, 120) : "No clipboard is available here",
      duration: 2_500,
    });
  };
  const openSelected = () => {
    const url = selected()?.url;
    if (!url) return;
    // Without a desktop session, such as over SSH, copy the URL instead.
    if (!openUrl(url)) void copy(url);
  };
  const copySelected = () => {
    const row = selected();
    const value = row?.url ?? row?.copy ?? row?.label;
    if (value) void copy(value);
  };
  const scrollDetail = (delta: number) =>
    (detail as { scrollBy?: (rows: number) => void } | undefined)?.scrollBy?.(
      delta,
    );

  const normal: readonly Key[] = [
    {
      bind: "j,down",
      title: "Next row",
      hint: "j/k",
      label: "move",
      run: () => select(index() + 1),
    },
    { bind: "k,up", title: "Previous row", run: () => select(index() - 1) },
    { bind: "g,home", title: "First row", run: () => select(0) },
    {
      bind: "shift+g,end",
      title: "Last row",
      run: () => select(rows().length - 1),
    },
    {
      bind: "l,right,tab",
      title: "Next section",
      hint: "h/l",
      label: "section",
      run: () => cycle(1),
    },
    { bind: "h,left", title: "Previous section", run: () => cycle(-1) },
    ...[1, 2, 3, 4, 5].map(
      (position): Key => ({
        bind: String(position),
        title: `Show section ${position}`,
        enabled: () => visible().length >= position,
        run: () => show(visible()[position - 1]),
      }),
    ),
    {
      bind: "return",
      title: "Show details",
      hint: "⏎",
      label: "details",
      enabled: () => selected() !== undefined,
      run: () => setMode("detail"),
    },
    {
      bind: "o",
      title: "Open in a browser",
      hint: "o",
      label: "open",
      enabled: () => selected()?.url !== undefined,
      run: openSelected,
    },
    {
      bind: "y",
      title: "Copy",
      hint: "y",
      label: "copy",
      enabled: () => selected() !== undefined,
      run: copySelected,
    },
    {
      bind: "r",
      title: "Refresh this section",
      hint: "r/R",
      label: "refresh",
      run: () => refresh(false),
    },
    {
      bind: "shift+r",
      title: "Refresh every section",
      run: () => refresh(true),
    },
    {
      bind: "f",
      title: "Toggle full screen",
      hint: "f",
      label: "full screen",
      enabled: () => props.panel !== undefined,
      run: () => props.panel?.toggleFullscreen(),
    },
    {
      bind: "escape,q",
      title: "Close the workflow view",
      hint: "esc",
      label: "close",
      run: () => props.onClose(),
    },
  ];
  const details: readonly Key[] = [
    {
      bind: "j,down",
      title: "Scroll down",
      hint: "j/k",
      label: "scroll",
      run: () => scrollDetail(1),
    },
    { bind: "k,up", title: "Scroll up", run: () => scrollDetail(-1) },
    {
      bind: "o",
      title: "Open in a browser",
      hint: "o",
      label: "open",
      enabled: () => selected()?.url !== undefined,
      run: openSelected,
    },
    {
      bind: "y",
      title: "Copy",
      hint: "y",
      label: "copy",
      enabled: () => selected() !== undefined,
      run: copySelected,
    },
    {
      bind: "r",
      title: "Refresh this section",
      hint: "r",
      label: "refresh",
      run: () => refresh(false),
    },
    {
      bind: "escape,return,q",
      title: "Back to the list",
      hint: "esc",
      label: "back",
      run: () => setMode("normal"),
    },
  ];
  const keys = () => (mode() === "detail" ? details : normal);

  // Inside the session panel this layer is live only while the panel has
  // focus; the hint line then switches from how to focus it to these keys.
  props.context.keymap.layer(() => ({
    commands: keys().map((key) => ({
      bind: key.bind,
      title: key.title,
      group: "Workflow",
      enabled: key.enabled,
      run: () => {
        key.run();
      },
    })),
  }));

  const badge = () =>
    !focused() ? "PROMPT" : mode() === "detail" ? "DETAIL" : "NORMAL";
  const hints = createMemo(() => {
    if (!focused()) {
      const focus = props.context.keymap.shortcuts("pane.focus.right")[0];
      const close = props.context.keymap.shortcuts(OPEN)[0];
      return [
        ...(focus
          ? [{ key: focus, label: "focus this panel", enabled: true }]
          : []),
        ...(close ? [{ key: close, label: "close", enabled: true }] : []),
      ];
    }
    return keys().flatMap((key) =>
      key.hint === undefined
        ? []
        : [
            {
              key: key.hint,
              label: key.label ?? key.title,
              enabled: key.enabled ? key.enabled() : true,
            },
          ],
    );
  });
  const tabBadge = (id: SectionID) => {
    const tone = views()[id].summary?.tone;
    return tone === "error" || tone === "warn" || tone === "busy"
      ? tone
      : undefined;
  };
  const updated = createMemo(() => {
    const at = views()[section()].updated;
    return at === undefined
      ? undefined
      : `updated ${M.duration(now() - at)} ago`;
  });

  return (
    <box
      width="100%"
      height="100%"
      flexDirection="column"
      backgroundColor={surface()}
      paddingLeft={2}
      paddingRight={1}
      paddingTop={docked() ? 1 : 0}
      onMouseDown={() => {
        if (props.panel && !props.panel.focused) props.panel.focus();
      }}
    >
      <box
        flexDirection="row"
        justifyContent="space-between"
        gap={1}
        flexShrink={0}
      >
        <text
          fg={theme().text.base}
          wrapMode="none"
          truncate
          flexShrink={1}
          minWidth={0}
        >
          <b>Workflow</b>
          <span style={{ fg: theme().text.muted }}>
            {" "}
            {M.basename(props.location()?.directory ?? "") || "no directory"}
          </span>
        </text>
        <Show when={updated()}>
          {(value) => (
            <text fg={theme().text.muted} wrapMode="none" flexShrink={0}>
              {value()}
            </text>
          )}
        </Show>
      </box>
      <Show
        when={width() >= NARROW}
        fallback={
          <text fg={theme().text.base} wrapMode="none" flexShrink={0}>
            <b>{TITLES[section()]}</b>
            <span style={{ fg: theme().text.muted }}>
              {` ${visible().indexOf(section()) + 1}/${visible().length} · h/l section`}
            </span>
          </text>
        }
      >
        <box flexDirection="row" gap={2} flexShrink={0}>
          <For each={visible()}>
            {(id, position) => (
              <text
                wrapMode="none"
                flexShrink={0}
                fg={id === section() ? theme().text.base : theme().text.muted}
                onMouseUp={() => show(id)}
              >
                <span style={{ fg: theme().text.muted }}>
                  {position() + 1}{" "}
                </span>
                {id === section() ? <b>{TITLES[id]}</b> : TITLES[id]}
                <Show when={tabBadge(id)}>
                  {(tone) => (
                    <span style={{ fg: toneColor(theme(), tone()) }}>
                      {" "}
                      {M.glyph[tone()]}
                    </span>
                  )}
                </Show>
              </text>
            )}
          </For>
        </box>
      </Show>
      <box height={1} flexShrink={0} />
      <Show
        when={mode() === "normal"}
        fallback={
          <scrollbox
            ref={(element: unknown) => (detail = element)}
            flexGrow={1}
            minHeight={0}
          >
            <text fg={theme().text.base} wrapMode="word">
              <b>{selected()?.label ?? ""}</b>
            </text>
            <Show when={selected()?.detail}>
              {(value) => (
                <text fg={theme().text.muted} wrapMode="word">
                  {value()}
                </text>
              )}
            </Show>
            <For each={selected()?.lines ?? []}>
              {(line) => (
                <text fg={theme().text.base} wrapMode="word">
                  {line}
                </text>
              )}
            </For>
          </scrollbox>
        }
      >
        <scrollbox
          ref={(element: unknown) => (list = element)}
          flexGrow={1}
          minHeight={0}
        >
          <Index each={rows()}>
            {(row, position) => (
              <box
                flexDirection="row"
                gap={1}
                minWidth={0}
                backgroundColor={
                  position === index() && focused() ? highlight() : surface()
                }
                onMouseUp={() => {
                  if (position === index()) setMode("detail");
                  else select(position);
                }}
              >
                <text flexShrink={0} fg={toneColor(theme(), row().tone)}>
                  {M.glyph[row().tone]}
                </text>
                <text
                  fg={theme().text.base}
                  wrapMode="none"
                  truncate
                  flexGrow={1}
                  flexShrink={1}
                  minWidth={0}
                >
                  {row().label}
                  <Show when={row().detail}>
                    {(value) => (
                      <span
                        style={{ fg: theme().text.muted }}
                      >{`  ${value()}`}</span>
                    )}
                  </Show>
                </text>
              </box>
            )}
          </Index>
        </scrollbox>
      </Show>
      <box
        flexDirection="row"
        gap={1}
        flexShrink={0}
        paddingTop={1}
        paddingBottom={docked() ? 1 : 0}
      >
        <box
          flexShrink={0}
          paddingLeft={1}
          paddingRight={1}
          backgroundColor={
            !focused()
              ? theme().background.raised.high
              : mode() === "detail"
                ? theme().text.feedback.info.base
                : theme().text.base
          }
        >
          <text
            fg={focused() ? theme().background.base : theme().text.muted}
            wrapMode="none"
          >
            <b>{badge()}</b>
          </text>
        </box>
        <text flexGrow={1} flexShrink={1} minWidth={0} wrapMode="word">
          <For each={hints()}>
            {(hint) => (
              <>
                <span
                  style={{
                    fg: hint.enabled ? theme().text.base : theme().text.muted,
                  }}
                >
                  {hint.key}
                </span>
                <span
                  style={{ fg: theme().text.muted }}
                >{` ${hint.label}   `}</span>
              </>
            )}
          </For>
        </text>
      </box>
    </box>
  );
}

function Commands(props: { context: Context; toggle: () => void }) {
  props.context.keymap.layer(() => ({
    mode: "global",
    commands: [
      {
        id: OPEN,
        title: "Workflow status",
        description:
          "Version control, CI, background jobs, luvus tasks, and the NixOS switch",
        group: "Workflow",
        // After the leader, o opens the overview, as Luvus's prefix and o open its board.
        bind: "<leader>o",
        palette: true,
        slash: { name: "workflow" },
        run: () => props.toggle(),
      },
    ],
  }));
  return null;
}

export default Plugin.define({
  id: "dotfiles.workflow-status",
  setup(context) {
    const hubs = createHubs((notice) => {
      context.ui.toast.show({
        variant: notice.variant,
        title: notice.title,
        message: notice.message,
        duration: notice.variant === "error" ? 10_000 : 5_000,
      });
      if (notice.variant === "error")
        void context.attention
          .notify({
            title: notice.title,
            message: notice.message,
            notification: { when: "blurred" },
            sound: { name: "error", when: "blurred" },
          })
          .catch(() => undefined);
    });
    const [request, setRequest] = createSignal<Request>();
    let previous: Route = { type: "home" };

    // The command toggles the view; a sidebar row opens it at its section.
    const toggle = (section?: SectionID) => {
      if (section) setRequest({ section, at: Date.now() });
      const route = context.ui.router.current();
      context.ui.dialog.clear();
      const current = context.ui.panel.current();
      if (
        route.type === "session" &&
        current?.name === PANEL &&
        current.sessionID === route.sessionID
      ) {
        if (!section) context.ui.panel.close();
        return;
      }
      if (context.ui.panel.open(PANEL)) return;
      // Outside a session there is no panel, so the view takes the screen.
      if (route.type === "plugin" && route.name === PANEL) {
        if (!section) context.ui.router.navigate(previous);
        return;
      }
      // The router hands out a live store; keep a copy of where to return.
      previous =
        route.type === "session"
          ? { type: "session", sessionID: route.sessionID }
          : route.type === "plugin"
            ? {
                type: "plugin",
                id: route.id,
                name: route.name,
                ...(route.data ? { data: { ...route.data } } : {}),
              }
            : { type: "home" };
      context.ui.router.navigate({ type: "plugin", name: PANEL });
    };

    const unlisten = context.data.listen(({ details }) => {
      if (ACTIVITY.test(details.type)) hubs.activity();
    });

    context.ui.slot({
      append: "sidebar.content",
      render: (input) => (
        <SidebarSection
          context={context}
          hubs={hubs}
          sessionID={input.sessionID}
          open={toggle}
        />
      ),
    });
    context.ui.slot({
      append: "home.footer.status",
      render: () => (
        <HomeStatus context={context} hubs={hubs} open={() => toggle()} />
      ),
    });
    context.ui.slot({
      append: "session.panel",
      render: (panel) => (
        <Show when={panel.name === PANEL}>
          <WorkflowView
            context={context}
            hubs={hubs}
            panel={panel}
            location={() =>
              context.data.session.get(panel.sessionID)?.location ??
              context.location
            }
            request={request}
            onClose={() => panel.close()}
          />
        </Show>
      ),
    });
    context.ui.router.register({
      name: PANEL,
      render: () => (
        <box
          width="100%"
          height="100%"
          backgroundColor={context.theme.background.base}
          paddingTop={1}
          paddingBottom={1}
        >
          <WorkflowView
            context={context}
            hubs={hubs}
            location={() => context.location}
            request={request}
            onClose={() => context.ui.router.navigate(previous)}
          />
        </box>
      ),
    });
    context.ui.slot({
      append: "app",
      render: () => <Commands context={context} toggle={() => toggle()} />,
    });

    return () => {
      unlisten();
      hubs.dispose();
    };
  },
});
