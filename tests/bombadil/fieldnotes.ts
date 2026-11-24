// Fieldnotes, the agent dashboard (modules/tooling/ai/claude/fieldnotes-package.nix),
// against the keymap rules. Offline in the build sandbox, each panel shows its
// source's error; the modes and keys work all the same.
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

// The mode badge starts the second-to-last row, above the hint line.
function mode(): string | null {
  const status = (rows().at(-2) ?? "").match(
    /^\s*(NORMAL|FILTER|DETAIL|CONFIRM)\s/,
  );
  return status ? status[1] : null;
}

export const modeShown = modeAlwaysShown(mode);
export const escapeReturnsToNormal = escapeReturnsTo("NORMAL", mode);

// The bottom row always lists the keys that work.
export const hintsShown = always(
  settles(() => (rows().at(-1) ?? "").trim() !== ""),
);

// `/` filters, Enter opens details, `x` asks to rerun a failed run, and the
// digits and Tab switch panels. `q` quits, which would end the exploration.
export const typing = keys(
  ["/", "\r", "x", "\t", "1", "2", "3", "4", "5"],
  ["q", "Q"],
);
