// Helix with this configuration's settings and keys
// (modules/tooling/editors/helix.nix) against the keymap rules.
import { always } from "@antithesishq/bombadil";
import { escapeReturnsTo, keys, modeAlwaysShown, rows } from "./keymap.ts";
export {
  exitSuccess,
  noReplacementChars,
} from "@antithesishq/bombadil/terminal/defaults/properties";

// The statusline, the second-to-last row, starts with the mode. While a
// prompt's completions cover it, the prompt on the last row (`:`, `/`,
// `search:`) names the mode instead.
function mode(): string | null {
  const screen = rows();
  const status = screen
    .slice(-2)
    .join("\n")
    .match(/(?:^|\s)(NOR|INS|SEL)\s/m);
  if (status) return status[1];
  const prompt = (screen[screen.length - 1] ?? "").match(/^([\w-]*[:/?])/);
  return prompt ? prompt[1] : null;
}

// Pending keys are drawn at the right of the last row.
const menuPrefix = /\s{2}(<space>w?|<C-w>|g|m|z|Z|\[|\])\s*$/;

function infobox(): boolean {
  const screen = rows();
  return (
    screen.some((row) => row.includes("┐")) &&
    screen.some((row) => row.includes("┘"))
  );
}

export const modeShown = modeAlwaysShown(mode);
export const escapeReturnsToNormal = escapeReturnsTo("NOR", mode);

// The last row is drawn after the rows above it, so once the pending keys
// show, the same frame already holds the infobox listing what follows them.
export const prefixShowsInfobox = always(
  () => !menuPrefix.test(rows().at(-1) ?? "") || infobox(),
);

export const typing = keys([" ", "g", "m", "z", "[", "]", ":", "v", "i"]);
