// jjui (programs.jjui, default settings) in a two-change repository against
// the keymap rules. It runs from remoteChecks (modules/tooling/keymap-checks/
// remote.nix) and fails until jjui changes: it calls its base mode
// `revisions` rather than NORMAL, and its help and command prompt show no
// mode.
import { always } from "@antithesishq/bombadil";
import {
  escapeReturnsTo,
  keys,
  modeAlwaysShown,
  rows,
  settles,
} from "./keymap.ts";
export {
  exitSuccess,
  noReplacementChars,
} from "@antithesishq/bombadil/terminal/defaults/properties";

// The bottom row starts with the mode, one or two lowercase words
// (`revisions`, `rebase`, `set bookmark`), then the keys that work in it.
function mode(): string | null {
  const status = (rows().at(-1) ?? "").match(/^\s*([a-z]+(?: [a-z]+)?)\s{2,}/);
  return status ? status[1] : null;
}

export const modeShown = modeAlwaysShown(mode);
export const escapeReturnsToNormal = escapeReturnsTo("NORMAL", mode);

// The bottom row always lists the keys that work.
export const hintsShown = always(
  settles(() => (rows().at(-1) ?? "").trim() !== ""),
);

// The keys that open jjui's modes and menus: rebase, squash, details, the
// revset, git and bookmark menus, help and the command prompt. `q` quits.
export const typing = keys(
  ["r", "S", "l", "L", "g", "b", "B", "?", ":"],
  ["q", "Q"],
);
