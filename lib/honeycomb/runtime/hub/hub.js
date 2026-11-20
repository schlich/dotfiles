// The phone's honeycomb (lib/honeycomb/README.md): the seven areas as one
// flower, and inside each area at most six of anything per screen.
//
// Three ways to move, as everywhere else:
//   in / out        tap a cell, flick from the centre toward one, or spread two
//                   fingers / Android's back gesture, or pinch
//   left / right    swipe sideways: the next area, kind or item
//   up / down       swipe up or down: the next six of a long list
// Selecting an item is the SELECT mode; its actions sit around it, and back
// returns to NORMAL. Keys work too: h l y u n m for the six directions, j k
// for the stack, i and o (or Escape) for in and out.

const LIMIT = 6;
const COMPASS = ["e", "se", "sw", "w", "nw", "ne"];
const AXIAL = {
  e: [1, 0],
  se: [0, 1],
  sw: [-1, 1],
  w: [-1, 0],
  nw: [0, -1],
  ne: [1, -1],
};
const ARROW = { e: "→", se: "↘", sw: "↙", w: "←", nw: "↖", ne: "↗" };
const KEYS = { l: "e", m: "se", n: "sw", h: "w", y: "nw", u: "ne" };
const KINDS = [
  { key: "sessions", title: "Sessions", cell: "e", one: "session" },
  { key: "tasks", title: "Tasks", cell: "se", one: "task" },
  { key: "windows", title: "Windows", cell: "sw", one: "window" },
  { key: "notes", title: "Notes", cell: "w", one: "note" },
];
const SVG = "http://www.w3.org/2000/svg";

const flowerEl = document.getElementById("flower");
const surface = document.getElementById("surface");
const modeEl = document.getElementById("mode");
const pathEl = document.getElementById("path");
const keysEl = document.getElementById("keys");
const statusEl = document.getElementById("status");
const confirmEl = document.getElementById("confirm");

let data = loadCached();
let offline = false;
let notice = "";
let view = null;

// ---- data ---------------------------------------------------------------

function loadCached() {
  try {
    return JSON.parse(localStorage.getItem("honeycomb:last") ?? "null");
  } catch {
    return null;
  }
}

async function refresh() {
  try {
    const response = await fetch("/api/flower", { cache: "no-store" });
    if (!response.ok) throw new Error(response.statusText);
    data = await response.json();
    offline = false;
    try {
      localStorage.setItem("honeycomb:last", JSON.stringify(data));
    } catch {}
  } catch {
    offline = true;
  }
  render();
}

const areas = () => data?.flower?.areas ?? [];
const pending = () => data?.pending ?? [];
const failed = () => data?.failed ?? [];

function area(name) {
  if (name === "unfiled") {
    const kinds = data?.flower?.unfiled;
    return kinds
      ? { name: "unfiled", title: "Unfiled", cell: "out", kinds }
      : null;
  }
  return areas().find((a) => a.name === name) ?? null;
}

const total = (a, kind) => a?.kinds?.[kind]?.total ?? 0;
const items = (a, kind) => a?.kinds?.[kind]?.items ?? [];
const plural = (n, one) => `${n} ${one}${n === 1 ? "" : "s"}`;

function ago(ms) {
  if (!ms) return "";
  const minutes = Math.round((Date.now() - ms) / 60000);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  return hours < 48 ? `${hours} h ago` : `${Math.round(hours / 24)} d ago`;
}

// ---- routes: #/AREA/KIND/PAGE/ITEM/SUB ---------------------------------

function parse() {
  const parts = location.hash
    .replace(/^#\/?/, "")
    .split("/")
    .filter(Boolean)
    .map(decodeURIComponent);
  const [areaName, kind, page, item, sub] = parts;
  return {
    areaName,
    kind,
    page: Number(page) || 1,
    item,
    sub,
    depth: parts.length >= 3 ? parts.length - 1 : parts.length,
  };
}

function href({ areaName, kind, page = 1, item, sub } = {}) {
  const parts = [areaName, kind, kind ? String(page) : null, item, sub].filter(
    (p) => p != null && p !== "",
  );
  return "#/" + parts.map(encodeURIComponent).join("/");
}

function go(target, { replace = false, motion = "zoom-in" } = {}) {
  if (replace) history.replaceState({ depth: depthOf(target) }, "", target);
  else history.pushState({ depth: depthOf(target) }, "", target);
  render(motion);
}

function depthOf(target) {
  const parts = target.replace(/^#\/?/, "").split("/").filter(Boolean);
  return parts.length >= 3 ? parts.length - 1 : parts.length;
}

function out() {
  if (parse().depth > 0) history.back();
}

addEventListener("popstate", () => render("zoom-out"));

// A deep link gets its ancestors in history, so back walks out level by
// level instead of leaving the app.
function seedHistory() {
  const route = parse();
  if (route.depth === 0) {
    history.replaceState({ depth: 0 }, "", "#/");
    return;
  }
  const chain = [
    "#/",
    href({ areaName: route.areaName }),
    route.kind &&
      href({ areaName: route.areaName, kind: route.kind, page: route.page }),
    route.item &&
      href({
        areaName: route.areaName,
        kind: route.kind,
        page: route.page,
        item: route.item,
      }),
    route.sub && href(route),
  ].filter(Boolean);
  history.replaceState({ depth: 0 }, "", chain[0]);
  for (const step of chain.slice(1))
    history.pushState({ depth: depthOf(step) }, "", step);
}

// ---- views: a centre, up to six cells around it, and where else to go --

function areaCell(a) {
  if (!a) return null;
  const sessions = total(a, "sessions");
  const rest = [
    total(a, "tasks") && plural(total(a, "tasks"), "task"),
    total(a, "windows") && plural(total(a, "windows"), "window"),
  ]
    .filter(Boolean)
    .join(" · ");
  return {
    label: a.title,
    sub: sessions ? plural(sessions, "session") : "no sessions",
    sub2: rest,
    over: KINDS.some((k) => k.key !== "notes" && total(a, k.key) > LIMIT),
    href: href({ areaName: a.name }),
  };
}

function pendingFor(target) {
  return pending().filter((p) => p.target === target);
}
function failedFor(target) {
  return failed().filter((p) => p.target === target);
}

function itemCell(a, kind, page, item) {
  const base = {
    label: item.title || "(untitled)",
    href: href({
      areaName: a.name,
      kind,
      page,
      item: String(item.id ?? item.title),
    }),
  };
  switch (kind) {
    case "sessions": {
      const waiting = pendingFor(item.id)
        .map((p) => p.kind)
        .join(", ");
      return {
        ...base,
        sub: ago(item.active),
        sub2: waiting ? `waiting: ${waiting}` : item.gone ? "folder gone" : "",
      };
    }
    case "tasks":
      return {
        ...base,
        sub: item.status,
        sub2: item.changed ? plural(item.changed, "file") : "",
      };
    case "windows":
      return { ...base, sub: item.app };
    default:
      return base;
  }
}

function findItem(a, kind, id) {
  return (
    items(a, kind).find((item) => String(item.id ?? item.title) === id) ?? null
  );
}

function buildView() {
  const route = parse();
  const flower = areas();
  if (!data?.flower) {
    return {
      title: "Honeycomb",
      crumbs: [],
      centre: {
        label: "Waiting",
        sub: "for asus to send",
        sub2: "its first snapshot",
      },
      ring: {},
      mode: "NORMAL",
    };
  }
  const crumbs = [{ label: "Areas", href: "#/" }];

  // The flower of areas.
  if (route.depth === 0) {
    const ring = {};
    for (const a of flower) if (a.cell !== "centre") ring[a.cell] = areaCell(a);
    const home = flower.find((a) => a.cell === "centre");
    const unfiled = area("unfiled");
    return {
      title: "Honeycomb",
      crumbs,
      mode: "NORMAL",
      ring,
      centre: areaCell(home),
      outward:
        unfiled && total(unfiled, "sessions") + total(unfiled, "tasks")
          ? {
              label: `Unfiled: ${total(unfiled, "sessions")}`,
              href: href({ areaName: "unfiled" }),
            }
          : null,
    };
  }

  const a = area(route.areaName);
  if (!a)
    return {
      title: "Not found",
      crumbs,
      centre: { label: "No such area", href: "#/" },
      ring: {},
      mode: "NORMAL",
    };
  crumbs.push({ label: a.title, href: href({ areaName: a.name }) });
  const order = a.name === "unfiled" ? [] : flower.map((x) => x.name);
  const step = (list, current, by) =>
    list.length > 1
      ? list[(list.indexOf(current) + by + list.length) % list.length]
      : null;

  // An area: its kinds of things around it.
  if (route.depth === 1) {
    const ring = {};
    for (const k of KINDS) {
      const n = total(a, k.key);
      if (a.kinds?.[k.key] == null) continue;
      ring[k.cell] = {
        label: k.title,
        sub: n ? String(n) : "none",
        over: k.key !== "notes" && n > LIMIT,
        dim: !n,
        href: n ? href({ areaName: a.name, kind: k.key }) : null,
      };
    }
    const first = KINDS.find((k) => total(a, k.key));
    const prev = step(order, a.name, -1),
      next = step(order, a.name, 1);
    return {
      title: a.title,
      crumbs,
      mode: "NORMAL",
      ring,
      centre: {
        ...areaCell(a),
        href: first ? href({ areaName: a.name, kind: first.key }) : null,
      },
      sideways: prev && {
        prev: href({ areaName: prev }),
        next: href({ areaName: next }),
        what: "area",
      },
    };
  }

  const kind = KINDS.find((k) => k.key === route.kind);
  if (!kind)
    return {
      title: "Not found",
      crumbs,
      centre: { label: "No such kind", href: href({ areaName: a.name }) },
      ring: {},
      mode: "NORMAL",
    };
  const list = items(a, kind.key);
  const pages = Math.max(1, Math.ceil(list.length / LIMIT));
  const page = Math.min(Math.max(route.page, 1), pages);
  crumbs.push({
    label: kind.title,
    href: href({ areaName: a.name, kind: kind.key, page }),
  });
  const kinds = KINDS.filter((k) => total(a, k.key)).map((k) => k.key);
  const kindStep = (by) => {
    const k = step(kinds, kind.key, by);
    return k && href({ areaName: a.name, kind: k });
  };

  // A kind: six of its items at a time, most recent first.
  if (route.depth === 2) {
    const ring = {};
    list.slice((page - 1) * LIMIT, page * LIMIT).forEach((item, i) => {
      ring[COMPASS[i]] = itemCell(a, kind.key, page, item);
    });
    const shown =
      list.length < total(a, kind.key) ? `, ${list.length} shown` : "";
    return {
      title: `${kind.title} · ${a.title}`,
      crumbs,
      mode: "NORMAL",
      ring,
      centre: {
        label: kind.title,
        sub: pages > 1 ? `${page} of ${pages}` : "",
        sub2: `${total(a, kind.key)} in all${shown}`,
      },
      sideways:
        kindStep(1) &&
        kindStep(1) !== href({ areaName: a.name, kind: kind.key })
          ? { prev: kindStep(-1), next: kindStep(1), what: "kind" }
          : null,
      stack:
        pages > 1
          ? {
              up:
                page > 1
                  ? href({ areaName: a.name, kind: kind.key, page: page - 1 })
                  : null,
              down:
                page < pages
                  ? href({ areaName: a.name, kind: kind.key, page: page + 1 })
                  : null,
            }
          : null,
    };
  }

  // An item, selected: what can be done to it sits around it.
  const item = findItem(a, kind.key, route.item);
  if (!item)
    return {
      title: "Gone",
      crumbs,
      centre: {
        label: "No longer here",
        sub: "it was archived or finished",
        href: href({ areaName: a.name, kind: kind.key, page }),
      },
      ring: {},
      mode: "NORMAL",
    };
  const itemHref = (sub) =>
    href({ areaName: a.name, kind: kind.key, page, item: route.item, sub });
  crumbs.push({ label: item.title || "(untitled)", href: itemHref() });
  const index = list.indexOf(item);
  const sibling = (by) => {
    const next = list[(index + by + list.length) % list.length];
    return href({
      areaName: a.name,
      kind: kind.key,
      page: Math.floor(list.indexOf(next) / LIMIT) + 1,
      item: String(next.id ?? next.title),
    });
  };

  if (route.depth === 4 && route.sub === "file") {
    const ring = {};
    let centre = null;
    for (const target of flower) {
      const cell = {
        label: target.title,
        sub:
          target.name === a.name
            ? "here now"
            : plural(total(target, "sessions"), "session"),
        dim: target.name === a.name,
      };
      if (target.name !== a.name)
        cell.action = () =>
          queue(
            {
              kind: "file",
              target: item.id,
              area: target.name,
              title: item.title,
            },
            `File into ${target.title}`,
          );
      if (target.cell === "centre") centre = cell;
      else ring[target.cell] = cell;
    }
    crumbs.push({ label: "File in", href: itemHref("file") });
    return {
      title: `File · ${item.title}`,
      crumbs,
      mode: "SELECT",
      ring,
      centre,
    };
  }

  if (route.depth === 4 && route.sub === "files") {
    const ring = {};
    (item.files ?? []).slice(0, LIMIT).forEach((file, i) => {
      ring[COMPASS[i]] = {
        label: file.path.split("/").pop(),
        sub: `+${file.added} −${file.removed}`,
        sub2: file.path.split("/").slice(0, -1).join("/"),
      };
    });
    crumbs.push({ label: "Files", href: itemHref("files") });
    const more = (item.changed ?? 0) - Math.min(item.changed ?? 0, LIMIT);
    return {
      title: `Files · ${item.title}`,
      crumbs,
      mode: "SELECT",
      ring,
      centre: {
        label: plural(item.changed ?? 0, "file"),
        sub: more ? `${more} more` : "",
        sub2: item.branch,
      },
    };
  }

  const ring = {};
  const details = itemCell(a, kind.key, page, item);
  if (kind.key === "sessions") {
    if (item.link)
      ring.e = {
        label: "Open",
        sub: "in Claude",
        href: item.link,
        external: true,
      };
    ring.se = {
      label: "File in…",
      sub: "another area",
      href: itemHref("file"),
    };
    ring.sw = {
      label: "Archive",
      sub: "when Claude closes",
      action: () => confirmArchive(item),
    };
    const waiting = pendingFor(item.id);
    if (waiting.length)
      ring.w = {
        label: "Cancel",
        sub: `waiting: ${waiting.map((p) => p.kind).join(", ")}`,
        action: () => cancel(waiting),
      };
    const failure = failedFor(item.id).at(-1);
    if (failure)
      ring.nw = {
        label: "Failed",
        sub: failure.kind,
        sub2: failure.note,
        dim: true,
      };
  } else if (kind.key === "tasks" && item.changed) {
    ring.e = {
      label: "Files",
      sub: plural(item.changed, "file"),
      href: itemHref("files"),
    };
  }
  return {
    title: item.title,
    crumbs,
    mode: "SELECT",
    ring,
    centre: {
      label: details.label,
      sub: details.sub,
      sub2:
        details.sub2 ||
        (Object.keys(ring).length ? "" : "nothing to do here yet"),
    },
    sideways:
      list.length > 1
        ? { prev: sibling(-1), next: sibling(1), what: kind.one }
        : null,
  };
}

// ---- actions ------------------------------------------------------------

async function queue(action, what) {
  try {
    const response = await fetch("/api/actions", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(action),
    });
    if (!response.ok)
      throw new Error(
        (await response.json().catch(() => ({}))).error ?? response.statusText,
      );
    say(`${what}: waiting for asus, which applies it while Claude is closed.`);
    await refresh();
    history.go(action.kind === "file" ? -2 : -1);
  } catch (error) {
    say(`Could not queue it: ${error.message}`);
    render();
  }
}

async function cancel(actions) {
  await Promise.all(
    actions.map((a) =>
      fetch(`/api/actions/${encodeURIComponent(a.id)}`, {
        method: "DELETE",
      }).catch(() => null),
    ),
  );
  say("Cancelled.");
  await refresh();
}

// A one-line message in the status line, for a few seconds.
let noticeTimer = 0;
function say(text) {
  notice = text;
  clearTimeout(noticeTimer);
  noticeTimer = setTimeout(() => {
    notice = "";
    render();
  }, 8000);
}

function confirmArchive(item) {
  document.getElementById("confirm-text").textContent =
    `Archive “${item.title}”? asus archives it the next time Claude is closed.`;
  confirmEl.returnValue = "";
  confirmEl.onclose = () => {
    if (confirmEl.returnValue === "ok")
      queue({ kind: "archive", target: item.id, title: item.title }, "Archive");
  };
  confirmEl.showModal();
}

// ---- drawing ------------------------------------------------------------

const SQRT3 = Math.sqrt(3);
function centreOf(direction) {
  if (!direction) return [0, 0];
  const [q, r] = AXIAL[direction];
  return [SQRT3 * (q + r / 2), 1.5 * r];
}

function hexPoints(cx, cy, size = 0.95) {
  return Array.from({ length: 6 }, (_, i) => {
    const angle = (Math.PI / 180) * (60 * i - 90);
    return `${(cx + size * Math.cos(angle)).toFixed(3)},${(cy + size * Math.sin(angle)).toFixed(3)}`;
  }).join(" ");
}

function wrap(text, width = 13, lines = 2) {
  const words = String(text).split(/\s+/);
  const out = [""];
  for (const word of words) {
    const line = out.at(-1);
    if (!line) out[out.length - 1] = word;
    else if ((line + " " + word).length <= width)
      out[out.length - 1] = line + " " + word;
    else out.push(word);
  }
  const kept = out
    .slice(0, lines)
    .map((l) => (l.length > width + 2 ? l.slice(0, width) + "…" : l));
  if (out.length > lines) kept[lines - 1] = kept[lines - 1].replace(/…?$/, "…");
  return kept;
}

function el(name, attributes = {}) {
  const node = document.createElementNS(SVG, name);
  for (const [key, value] of Object.entries(attributes))
    node.setAttribute(key, value);
  return node;
}

function drawCell(cell, direction, isCentre) {
  const [cx, cy] = centreOf(direction);
  const linked = cell && (cell.href || cell.action);
  const group = el(linked ? "a" : "g");
  group.classList.add("cell");
  if (isCentre) group.classList.add("centre");
  if (!cell) group.classList.add("empty");
  if (cell?.over) group.classList.add("over");
  if (cell?.dim) group.classList.add("dim");
  group.dataset.dir = direction ?? "centre";
  if (cell?.href) {
    group.setAttribute("href", cell.href);
    if (cell.external) {
      group.setAttribute("target", "_blank");
      group.setAttribute("rel", "noopener");
    }
  } else if (cell?.action) {
    group.setAttribute("href", "#");
    group.setAttribute("role", "button");
  }
  if (cell)
    group.setAttribute(
      "aria-label",
      [cell.label, cell.sub, cell.sub2].filter(Boolean).join(", "),
    );
  group.append(el("polygon", { points: hexPoints(cx, cy) }));
  if (cell) {
    const label = wrap(cell.label);
    const lines = [
      ...label.map((t) => ["label", t]),
      cell.sub && ["sub", cell.sub],
      cell.sub2 && ["sub", wrap(cell.sub2, 17, 1)[0]],
    ].filter(Boolean);
    let y = cy - (lines.length - 1) * 0.11;
    for (const [kind, text] of lines) {
      const node = el("text", {
        x: cx.toFixed(3),
        y: y.toFixed(3),
        class: kind,
        "dominant-baseline": "middle",
      });
      node.textContent = text;
      group.append(node);
      y += 0.22;
    }
    if (cell.over) {
      const flag = el("text", {
        x: cx.toFixed(3),
        y: (cy - 0.52).toFixed(3),
        class: "flag",
        "dominant-baseline": "middle",
      });
      flag.textContent = "over six";
      group.append(flag);
    }
  }
  return group;
}

function render(motion) {
  view = buildView();
  document.title =
    view.title === "Honeycomb" ? "Honeycomb" : `${view.title} | Honeycomb`;
  modeEl.textContent = view.mode;
  modeEl.dataset.mode = view.mode;

  pathEl.replaceChildren(
    ...view.crumbs.map((crumb, i) => {
      const span = document.createElement("span");
      if (i < view.crumbs.length - 1) {
        const link = document.createElement("a");
        link.href = crumb.href;
        link.textContent = crumb.label;
        link.addEventListener("click", (event) => {
          event.preventDefault();
          history.go(i - (view.crumbs.length - 1));
        });
        span.append(link);
      } else {
        span.textContent = crumb.label;
        span.setAttribute("aria-current", "location");
      }
      return span;
    }),
  );

  const cells = COMPASS.map((d) => drawCell(view.ring[d] ?? null, d, false));
  const centre = drawCell(view.centre, null, true);
  flowerEl.replaceChildren(...cells, centre);
  flowerEl.setAttribute("aria-label", view.title);
  if (motion) {
    flowerEl.classList.remove("zoom-in", "zoom-out", "slide");
    void flowerEl.getBoundingClientRect();
    flowerEl.classList.add(motion);
  }

  // Each direction's destination, on the edge it points to.
  for (const hint of document.querySelectorAll(".hint")) {
    const cell = view.ring[hint.dataset.dir];
    hint.textContent =
      cell && (cell.href || cell.action)
        ? `${ARROW[hint.dataset.dir]} ${cell.label}`
        : "";
  }

  const keys = ["tap or flick: in"];
  if (parse().depth > 0) keys.push("back or pinch: out");
  if (view.sideways) keys.push(`swipe ⇆: ${view.sideways.what}`);
  if (view.stack) keys.push("swipe ⇅: next six");
  if (view.mode === "SELECT") keys.push("back: NORMAL");
  keysEl.replaceChildren(
    ...keys.map((text) =>
      Object.assign(document.createElement("span"), { textContent: text }),
    ),
  );

  const parts = [];
  if (notice) parts.push(notice);
  if (offline) parts.push("offline, last snapshot");
  if (data?.flower?.generated)
    parts.push(
      `${data.flower.host ?? "host"} ${ago(Date.parse(data.flower.generated))}`,
    );
  if (pending().length) parts.push(`${pending().length} waiting`);
  if (failed().length) parts.push(`${failed().length} failed`);
  statusEl.replaceChildren(document.createTextNode(parts.join(" · ")));
  if (view.outward) {
    const link = Object.assign(document.createElement("a"), {
      href: view.outward.href,
      textContent: ` ${view.outward.label}`,
    });
    statusEl.append(" · ", link);
  }

  centre.focus?.({ preventScroll: true });
}

// ---- input --------------------------------------------------------------

function cellIn(direction) {
  return direction ? view?.ring[direction] : view?.centre;
}

function enter(cell) {
  if (!cell) return;
  if (cell.action) cell.action();
  else if (cell.external) window.open(cell.href, "_blank", "noopener");
  else if (cell.href) go(cell.href);
}

surface.addEventListener("click", (event) => {
  const link = event.target.closest("a.cell");
  if (!link) return;
  event.preventDefault();
  if (suppressClick) {
    suppressClick = false;
    return;
  }
  enter(cellIn(link.dataset.dir === "centre" ? null : link.dataset.dir));
});

const pointers = new Map();
let gesture = null;
let suppressClick = false;

surface.addEventListener("pointerdown", (event) => {
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  if (pointers.size === 1) {
    const onCentre = !!event.target.closest(".cell.centre");
    gesture = {
      x: event.clientX,
      y: event.clientY,
      t: performance.now(),
      onCentre,
      pinch: null,
    };
  } else if (pointers.size === 2 && gesture) {
    const [a, b] = [...pointers.values()];
    gesture.pinch = {
      start: Math.hypot(a.x - b.x, a.y - b.y),
      ratio: 1,
      mid: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
    };
  }
});

surface.addEventListener("pointermove", (event) => {
  if (!pointers.has(event.pointerId)) return;
  pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
  if (gesture?.pinch && pointers.size === 2) {
    const [a, b] = [...pointers.values()];
    gesture.pinch.ratio =
      Math.hypot(a.x - b.x, a.y - b.y) / gesture.pinch.start;
  }
});

function finish(event) {
  if (!pointers.has(event.pointerId)) return;
  pointers.delete(event.pointerId);
  if (!gesture || pointers.size > 0) return;
  const g = gesture;
  gesture = null;
  if (g.pinch) {
    suppressClick = true;
    setTimeout(() => {
      suppressClick = false;
    }, 0);
    if (g.pinch.ratio > 1.25) {
      const under = document
        .elementFromPoint(g.pinch.mid.x, g.pinch.mid.y)
        ?.closest("a.cell");
      enter(
        cellIn(
          under && under.dataset.dir !== "centre" ? under.dataset.dir : null,
        ),
      );
    } else if (g.pinch.ratio < 0.8) out();
    return;
  }
  const dx = event.clientX - g.x,
    dy = event.clientY - g.y;
  const distance = Math.hypot(dx, dy);
  if (distance < 12) return; // a tap; the click handler takes it
  suppressClick = true;
  setTimeout(() => {
    suppressClick = false;
  }, 0);
  if (g.onCentre && distance > 36 && performance.now() - g.t < 450) {
    // A flick from the centre: the nearest of the six directions.
    const sector = Math.round(Math.atan2(dy, dx) / (Math.PI / 3));
    enter(cellIn(COMPASS[(sector + 6) % 6]));
  } else if (Math.abs(dx) > 50 && Math.abs(dx) > 1.5 * Math.abs(dy)) {
    if (view?.sideways)
      go(dx < 0 ? view.sideways.next : view.sideways.prev, {
        replace: true,
        motion: "slide",
      });
  } else if (Math.abs(dy) > 50 && Math.abs(dy) > 1.5 * Math.abs(dx)) {
    const target = dy < 0 ? view?.stack?.down : view?.stack?.up;
    if (target) go(target, { replace: true, motion: "slide" });
  }
}

surface.addEventListener("pointerup", finish);
surface.addEventListener("pointercancel", (event) => {
  pointers.delete(event.pointerId);
  gesture = null;
});

addEventListener("keydown", (event) => {
  if (event.ctrlKey || event.metaKey || event.altKey || confirmEl.open) return;
  const key = event.key;
  if (KEYS[key]) enter(cellIn(KEYS[key]));
  else if (key === "i" || key === "Enter") enter(cellIn(null));
  else if (key === "o" || key === "Escape" || key === "Backspace") out();
  else if (key === "j" && view?.stack?.down)
    go(view.stack.down, { replace: true, motion: "slide" });
  else if (key === "k" && view?.stack?.up)
    go(view.stack.up, { replace: true, motion: "slide" });
  else if (key === "ArrowRight" && view?.sideways)
    go(view.sideways.next, { replace: true, motion: "slide" });
  else if (key === "ArrowLeft" && view?.sideways)
    go(view.sideways.prev, { replace: true, motion: "slide" });
  else return;
  event.preventDefault();
});

// ---- start --------------------------------------------------------------

seedHistory();
render();
refresh();
setInterval(() => {
  if (document.visibilityState === "visible") refresh();
}, 30000);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") refresh();
});
if ("serviceWorker" in navigator)
  navigator.serviceWorker.register("/sw.js").catch(() => {});
