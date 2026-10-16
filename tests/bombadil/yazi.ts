// Yazi with this configuration's settings and keymap
// (modules/programs/yazi.nix) against the keymap rules.
import { always } from "@antithesishq/bombadil";
import { escapeReturnsTo, keys, modeAlwaysShown, rows } from "./keymap.ts";
export {
  exitSuccess,
  noReplacementChars,
} from "@antithesishq/bombadil/terminal/defaults/properties";

// The status bar, the last row, starts with the mode after a separator
// glyph.
function mode(): string | null {
  const status = (rows().at(-1) ?? "").match(/^[^A-Za-z]*(NOR|SEL|UNS)\s/);
  return status ? status[1] : null;
}

export const modeShown = modeAlwaysShown(mode);
export const escapeReturnsToNormal = escapeReturnsTo("NOR", mode);

// The which-key list after `g` shows single keys (`h  Go home`; the help
// menu shows `gh`). Once its bottom border is drawn, it must list this
// configuration's `g n` with its description rather than its `cd ~/kb`
// command.
export const notesBindingDescribed = always(() => {
  const screen = rows();
  const home = screen.findIndex((row) => /(?:^|\s)h {2}Go home/.test(row));
  if (home < 0) return true;
  let top = home;
  while (top > 0 && !screen[top].includes("╭")) top--;
  const bottom = screen.findIndex((row, i) => i > home && row.includes("╰"));
  if (bottom < 0) return true;
  return screen
    .slice(top, bottom)
    .some((row) => /(?:^|\s)n {2}(?!cd )\S/.test(row));
});

export const typing = keys(["g", "c", ",", "v", "~"], ["q", "Q"]);
