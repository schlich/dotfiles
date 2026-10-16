// Fieldwork's desktop companion (xr-workbench) under Bombadil's browser
// defaults and the workbench's own invariants. The check's bridge serves a
// fixture repository, and its commands fail at once without jj or nix.
import { always, eventually, now } from "@antithesishq/bombadil";
import { extract } from "@antithesishq/bombadil/browser";
export * from "@antithesishq/bombadil/browser/defaults";

// Runs in the page, so it can use nothing from this module.
const page = extract((state) => {
  const doc = state.document;
  const text = (id: string) =>
    doc.getElementById(id)?.textContent?.trim() ?? null;
  const save = doc.getElementById("save-file") as HTMLButtonElement | null;
  return {
    connection: text("connection"),
    editorState: text("editor-state"),
    saveEnabled: save ? !save.disabled : null,
    tabs: Array.from(doc.querySelectorAll("[role=tab]")).map((tab) => ({
      selected: tab.getAttribute("aria-selected") === "true",
      shown: doc.getElementById(`${tab.id.slice(4)}-pane`)?.hidden === false,
    })),
    running: Array.from(doc.querySelectorAll("#job-select option")).some(
      (option) => (option.textContent ?? "").endsWith("· running"),
    ),
    actionEnabled: Array.from(
      doc.querySelectorAll<HTMLButtonElement>("button[data-action]"),
    ).some((button) => !button.disabled),
  };
});

// The bridge stays reachable: the status never reports it lost.
export const bridgeStaysUp = always(
  () => !/disconnected|unavailable/i.test(page.current?.connection ?? ""),
);

// Exactly one inspector tab is selected, and only its pane shows.
export const oneTabShown = always(() => {
  const tabs = page.current?.tabs ?? [];
  return (
    tabs.length === 0 ||
    (tabs.filter((tab) => tab.selected).length === 1 &&
      tabs.every((tab) => tab.selected === tab.shown))
  );
});

// The editor's label says "UNSAVED DRAFT" exactly when Save is enabled,
// once a save in flight has returned.
function draftMismatch(): boolean {
  const current = page.current;
  if (!current || current.saveEnabled === null) return false;
  return (current.editorState === "UNSAVED DRAFT") !== current.saveEnabled;
}
export const saveFollowsDraft = always(
  now(draftMismatch).implies(
    eventually(() => !draftMismatch()).within(5, "seconds"),
  ),
);

// The MCP trace page loads the recorded trace and each step's diagram:
// its error line stays empty.
const traceError = extract(
  (state) =>
    state.document.getElementById("trace-error")?.textContent?.trim() ?? "",
);
export const traceLoads = always(() => (traceError.current ?? "") === "");

// One command runs at a time: the next poll of the bridge disables every
// action while one runs.
function busy(): boolean {
  return !!page.current?.running && page.current.actionEnabled;
}
export const oneCommandAtATime = always(
  now(busy).implies(eventually(() => !busy()).within(4, "seconds")),
);
