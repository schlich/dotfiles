// The CI dashboard (tools/ci-dashboard) under Bombadil, against the real
// server with fake `ci` and `gh` commands whose world keeps changing: runs
// start, end, and get lost, logs grow mid-line or are replaced, topics move,
// and the tower is sometimes unreachable. Line numbers cite index.html.
import { always, eventually, next, now } from "@antithesishq/bombadil";
import {
  actions,
  extract,
  getFingerprint,
  registerCustomAction,
  weighted,
} from "@antithesishq/bombadil/browser";
import {
  clickablePoint,
  inViewport,
  isVisible,
  queryAll,
} from "@antithesishq/bombadil/browser/dom";
import {
  lastAction,
  reload,
  scroll,
  waitOnce,
} from "@antithesishq/bombadil/browser/defaults/actions";
export {
  noConsoleErrors,
  noHttpErrorCodes,
  noUncaughtExceptions,
  noUnhandledPromiseRejections,
} from "@antithesishq/bombadil/browser/defaults/properties";

// Runs in the page, so it can use nothing from this module.
const page = extract((state) => {
  const doc = state.document;
  const one = (selector: string) => doc.querySelector<HTMLElement>(selector);
  const text = (selector: string) => one(selector)?.textContent?.trim() ?? "";
  const count = (selector: string) => doc.querySelectorAll(selector).length;
  const refresh = one("#refresh-button") as HTMLButtonElement | null;
  const note = one("#feed-note");
  // Text the page renders from data, but not the logs it shows verbatim,
  // which may say anything and grow to megabytes. Reading text nodes forces
  // no layout, unlike innerText.
  let junk: string | null = null;
  const pending: Node[] = doc.body ? [doc.body] : [];
  while (pending.length > 0 && junk === null) {
    const node = pending.pop() as Node;
    if (node.nodeType === Node.TEXT_NODE) {
      const data = node.nodeValue ?? "";
      if (/\bundefined\b|\bNaN\b|\[object Object\]|Invalid Date/.test(data))
        junk = data.slice(0, 120);
    } else if (
      node instanceof Element &&
      !node.matches("#log-text, .log-block, script, style")
    ) {
      pending.push(...Array.from(node.childNodes));
    }
  }
  const perf = state.window.performance;
  // The default buffer of 250 entries would fill and hide later requests.
  perf.setResourceTimingBufferSize(100_000);
  const since = perf.now() - 3000;
  return {
    load: perf.timeOrigin,
    feed: one("#feed-state")?.dataset.state ?? "",
    label: text("#connection-label"),
    note: {
      hidden: note?.hidden ?? true,
      kind: note?.dataset.kind ?? "",
      text: note?.textContent ?? "",
    },
    refresh: {
      disabled: refresh?.disabled ?? false,
      syncing: refresh?.classList.contains("is-syncing") ?? false,
    },
    theme: {
      mode: doc.documentElement.dataset.theme ?? "",
      button: text("#theme-button"),
      label: one("#theme-button")?.getAttribute("aria-label") ?? "",
    },
    topicCount: {
      text: text("#topic-count"),
      tone: one("#topic-count")?.dataset.tone ?? "",
    },
    topicRows: count("#topics-body tr:not(:has(.empty-row))"),
    topicsBad: count("#topics-body .state-tag.bad"),
    locks: {
      hidden: one("#lock-list")?.hidden ?? true,
      items: count("#lock-list li"),
    },
    idle: {
      hidden: one("#idle-topics")?.hidden ?? true,
      text: text("#idle-topics"),
    },
    runsSummary: text("#runs-summary"),
    runRows: count("#run-list .run-row"),
    runsBad: count("#run-list .run-title-line .run-status.bad"),
    runsSubtitle: text("#runs-subtitle"),
    trunk: {
      items: count("#trunk-list .trunk-item"),
      pending: count("#trunk-list .trunk-item .state-tag.warn"),
      note: text("#trunk-note"),
    },
    actionsSummary: text("#actions-summary"),
    actionsBad: count("#actions-list .run-title-line .run-status.bad"),
    actionsWarn: count("#actions-list .run-title-line .run-status.warn"),
    logRuns: Array.from(doc.querySelectorAll("#log-runs .log-run")).map(
      (button) => ({
        pressed: button.getAttribute("aria-pressed") === "true",
        command: button.querySelector(".log-run-command")?.textContent ?? "",
        tag: button.querySelector(".state-tag")?.textContent?.trim() ?? "",
        tone: button.querySelector(".state-tag")?.className ?? "",
      }),
    ),
    logTitle: text("#log-title"),
    logFilter: (one("#log-filter") as HTMLSelectElement | null)?.value ?? "all",
    logChunks: one("#log-text")?.childElementCount ?? 0,
    junk,
    // Disclosures in both run panels, keyed the way each panel keys its rows.
    details: Array.from(
      doc.querySelectorAll("#run-list details, #actions-list details"),
    ).map((details) => {
      const row = details.closest<HTMLElement>(".run-row");
      const element = details.querySelector("summary");
      const summary = element?.textContent?.trim() ?? "";
      const box = element?.getBoundingClientRect();
      const panel = details.closest("#run-list") ? "local" : "actions";
      return {
        key: `${panel}:${row?.dataset.key ?? summary}`,
        summary,
        // Where its summary is, in viewport coordinates, as clicks give them.
        box: box
          ? {
              left: box.left,
              top: box.top,
              right: box.right,
              bottom: box.bottom,
            }
          : null,
        open: (details as HTMLDetailsElement).open,
        loadingSteps:
          (details as HTMLDetailsElement).open &&
          !!details
            .querySelector(".log-block")
            ?.textContent?.includes("Loading the failed steps"),
      };
    }),
    logReads: perf
      .getEntriesByType("resource")
      .filter(
        (entry) =>
          entry.name.includes("/api/runs/log") && entry.startTime > since,
      ).length,
  };
});

type Page = NonNullable<typeof page.current>;
const holds = (check: (current: Page) => boolean) => () =>
  page.current ? check(page.current) : true;
// Panels drawn from the tower snapshot keep their static placeholders ("—")
// until one arrives.
const shown = (check: (current: Page) => boolean) =>
  holds((current) => current.feed === "offline" || check(current));

// The feed indicator and its label agree (L1420-1429).
export const feedStateLabelled = always(
  holds(({ feed, label }) =>
    feed === "offline"
      ? ["CONNECTING", "FEED UNAVAILABLE"].includes(label)
      : feed === "live"
        ? ["LIVE SNAPSHOT", "IMPORTED SNAPSHOT"].includes(label)
        : feed === "stale" && label === "STALE SNAPSHOT",
  ),
);

// A stale snapshot always says so (L2238-2242), and a live one shows no note.
export const staleFeedIsMarked = always(
  holds(
    ({ feed, note }) =>
      feed !== "stale" || (!note.hidden && note.kind === "warning"),
  ),
);
export const liveFeedHasNoNote = always(
  holds(({ feed, note }) => feed !== "live" || note.hidden),
);

// Once a snapshot shows, the page keeps showing it, stale if need be, until
// it is loaded again (L2276-2282).
export const feedNeverDropsToOffline = always(() => {
  const before = page.current;
  const shown = !!before && before.feed !== "offline";
  return now(() => shown).implies(
    next(
      () =>
        !page.current ||
        page.current.load !== before?.load ||
        page.current.feed !== "offline",
    ),
  );
});

// Refresh is disabled exactly while it syncs (L2254, L2290), and a sync ends.
export const refreshShowsSyncing = always(
  holds(({ refresh }) => refresh.disabled === refresh.syncing),
);
export const refreshFinishes = always(
  now(holds(({ refresh }) => refresh.syncing)).implies(
    eventually(holds(({ refresh }) => !refresh.syncing)).within(25, "seconds"),
  ),
);

// The theme button offers the other theme (L2295-2301).
export const themeControlsAgree = always(
  holds(({ theme }) =>
    theme.mode === "dark"
      ? theme.button === "Light" && theme.label === "Switch to light theme"
      : theme.mode === "light" &&
        theme.button === "Dark" &&
        theme.label === "Switch to dark theme",
  ),
);

// The topic count counts the rows it summarizes (L1660-1667).
export const topicCountMatchesRows = always(
  shown(({ topicCount, topicRows, topicsBad }) => {
    const n = Number(topicCount.text.match(/^\d+/)?.[0] ?? NaN);
    return topicCount.tone === "bad"
      ? n === topicsBad && n > 0
      : n === topicRows;
  }),
);

// Empty lock and idle rows are hidden, and only those (L1668, L1934).
export const emptyRowsHidden = always(
  shown(
    ({ locks, idle }) =>
      locks.hidden === (locks.items === 0) &&
      idle.hidden === (idle.text === ""),
  ),
);

// The local runs' summary counts the rows it summarizes (L1716-1728).
export const runsSummaryMatchesRows = always(
  shown(({ runsSummary, runRows, runsBad }) => {
    const failed = runsSummary.match(/^(\d+) failed$/);
    const running = runsSummary.match(/^(\d+) running$/);
    if (failed) return Number(failed[1]) === runsBad;
    if (running) return Number(running[1]) === runRows && runsBad === 0;
    return runsSummary !== "All clear" || runRows === 0;
  }),
);
export const runsSubtitleCounts = always(
  shown(({ runsSubtitle }) => {
    const counts = runsSubtitle.match(/^(\d+) runs in 24h · (\d+) passed$/);
    return !!counts && Number(counts[2]) <= Number(counts[1]);
  }),
);

// A failed or lost run never looks like a pass (L1432-1466, L1690, L1745).
export const failedRunsLookFailed = always(
  holds(({ logRuns }) =>
    logRuns.every(
      ({ tag, tone }) =>
        !["lost", "Failed"].includes(tag) || tone.split(" ").includes("bad"),
    ),
  ),
);

// Trunk shows six changes at most, and its note counts the unactivated ones
// it marks (L1946-1985).
export const trunkCountsUnactivated = always(
  shown(({ trunk }) => {
    const pending = trunk.note.match(/^(\d+) landed after/);
    return (
      trunk.items <= 6 &&
      (pending ? Number(pending[1]) === trunk.pending : trunk.pending === 0)
    );
  }),
);

// The Actions summary counts its failing rows (L2188-2198).
export const actionsSummaryMatchesRows = always(
  holds(({ actionsSummary, actionsBad, actionsWarn }) => {
    const failing = actionsSummary.match(/^CI (\d+) failing$/);
    if (failing) return Number(failing[1]) === actionsBad;
    return actionsSummary !== "CI passing" || actionsBad + actionsWarn === 0;
  }),
);

// At most one log is selected, and the log pane shows that one (L1783-1798).
export const oneLogSelected = always(
  holds(({ logRuns, logTitle }) => {
    const pressed = logRuns.filter((run) => run.pressed);
    return (
      logRuns.length <= 60 &&
      pressed.length <= 1 &&
      pressed.every((run) => logTitle.startsWith(`${run.command} · `))
    );
  }),
);

// The log list shows only what its filter asks for (L1740-1747).
export const logFilterRespected = always(
  holds(({ logFilter, logRuns }) =>
    logRuns.every(({ tag }) =>
      logFilter === "running"
        ? ["Running", "Blocked", "Queued"].includes(tag)
        : logFilter === "failed"
          ? ["Failed", "lost"].includes(tag)
          : true,
    ),
  ),
);

// The log pane keeps at most 400 chunks (L1836).
export const logChunksBounded = always(
  holds(({ logChunks }) => logChunks <= 400),
);

// Every value the page renders was there to render.
export const noUnrenderedValues = always(holds(({ junk }) => junk === null));

// Following a log reads it again at once only while there is more to read,
// not while its last line is still being written (L1873).
export const logPollingIsBounded = always(
  holds(({ logReads }) => logReads <= 15),
);

// An opened GitHub run shows its failed steps, or why it cannot (L2036-2068).
export const failedStepsLoad = always(
  now(
    holds(({ details }) => details.some((entry) => entry.loadingSteps)),
  ).implies(
    eventually(
      holds(({ details }) => !details.some((entry) => entry.loadingSteps)),
    ).within(15, "seconds"),
  ),
);

// A run's open detail stays open while the run is listed, unless the user
// closes it: Actions keeps its rows open across refreshes (L2139-2180), and
// so must the local runs.
export const openDetailsStayOpen = always(() => {
  const opened = (page.current?.details ?? []).filter((entry) => entry.open);
  return next(() => {
    const current = page.current;
    const action = lastAction.current;
    if (!current || opened.length === 0) return true;
    if (typeof action === "string" && action !== "Wait") return true;
    if (action && typeof action === "object" && "PressKey" in action)
      return true;
    // A click toggles whatever is at its point when it lands, which can be
    // another element than the one it was aimed at once the page has moved:
    // a summary was clicked if the point was on it or the click named it.
    // The action arrives serialized, with its fingerprint's fields in
    // snake_case, whatever the Fingerprint type says.
    const click =
      action && typeof action === "object" && "Click" in action
        ? action.Click
        : null;
    const fingerprint = (click?.fingerprint ?? null) as Record<
      string,
      unknown
    > | null;
    const clicked =
      fingerprint?.textContent ?? fingerprint?.text_content ?? null;
    const hit = (
      box: { left: number; top: number; right: number; bottom: number } | null,
    ) =>
      !!click &&
      !!box &&
      click.point.x >= box.left &&
      click.point.x <= box.right &&
      click.point.y >= box.top &&
      click.point.y <= box.bottom;
    return opened.every(
      (entry) =>
        entry.summary === clicked ||
        hit(entry.box) ||
        !current.details.some((other) => other.key === entry.key) ||
        current.details.some((other) => other.key === entry.key && other.open),
    );
  });
});

// Actions. Bombadil's default clicks skip <summary>, the disclosures most of
// this page hangs on, and would open the snapshot import's file chooser.
const clickable = extract((state) => {
  if (!state.document.body) return [];
  const targets = [];
  for (const element of queryAll(
    state.document.body,
    "button:not(:disabled), input:not([type=file]):not(:disabled), summary, a:not([target=_blank])",
  )) {
    if (
      !(element instanceof HTMLInputElement) &&
      !isVisible(state.window, element)
    )
      continue;
    const point = clickablePoint(element);
    if (!point || !inViewport(state.window, point)) continue;
    targets.push({ fingerprint: getFingerprint(element), point });
  }
  return targets;
});
export const clicks = actions(() =>
  (clickable.current ?? []).map((target) => ({ Click: target })),
);

const chooseLogFilter = registerCustomAction(
  "chooseLogFilter",
  async (document, _window, value: string) => {
    const select = document.querySelector<HTMLSelectElement>("#log-filter");
    if (!select) return;
    select.value = value;
    select.dispatchEvent(new Event("change", { bubbles: true }));
  },
);
const scrollLog = registerCustomAction(
  "scrollLog",
  async (document, _window, fraction: number) => {
    const pre = document.querySelector<HTMLElement>("#log-text");
    if (pre) pre.scrollTop = fraction * pre.scrollHeight;
  },
);
export const pageActions = weighted([
  [
    20,
    actions(() =>
      ["all", "running", "failed"].map((value) => chooseLogFilter(value)),
    ),
  ],
  [10, actions(() => [0, 0.5, 1].map((fraction) => scrollLog(fraction)))],
  // Tab, Enter, Space, and Esc reach summaries and buttons from the keyboard.
  [20, actions(() => [9, 13, 32, 27].map((code) => ({ PressKey: { code } })))],
]);
export const pageMoves = weighted([
  [30, scroll],
  [20, waitOnce],
  [3, reload],
]);
