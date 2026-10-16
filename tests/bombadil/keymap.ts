// The keymap rules every terminal UI here must meet, as Bombadil properties:
// the current mode is always on screen, a prefix key shows the keys that
// follow it, and Esc returns to the base mode. Each program's specification
// says where its mode and hints are drawn.
import { always, eventually, next, type Formula } from "@antithesishq/bombadil";
import { CharSet } from "@antithesishq/bombadil/actions";
import { extract, weighted } from "@antithesishq/bombadil/terminal";
import {
  CharSets,
  lastAction,
  typeFromSet,
} from "@antithesishq/bombadil/terminal/defaults/actions";

export const screen = extract((state) => {
  const rows: string[] = [];
  for (let row = 0; row < state.grid.size.rows; row++) {
    rows.push(state.grid.rowText(row));
  }
  return rows;
});

export function rows(): string[] {
  return screen.current ?? [];
}

// Bombadil can sample a redraw half drawn, and a program may hand the
// terminal to a child (an opener, a shell command) for a moment, so a
// condition that must hold after each key only has to hold again soon.
export function settles(condition: () => boolean): Formula {
  return eventually(condition).within(3, "seconds");
}

export function modeAlwaysShown(mode: () => string | null): Formula {
  return always(settles(() => mode() !== null));
}

function escaped(): boolean {
  const action = lastAction.current;
  return !!action && "TypeText" in action && action.TypeText === "\x1b";
}

// The first Esc may only close a prompt or menu; the second must reach the
// base mode.
export function escapeReturnsTo(
  base: string,
  mode: () => string | null,
): Formula {
  return always(() => {
    const first = escaped();
    return next(() => !(first && escaped()) || settles(() => mode() === base));
  });
}

// Random typing, weighted toward Esc and the program's prefix keys so menus
// open and close often. `avoid` drops single keys that quit the program,
// which would end the exploration early.
export function keys(prefixes: string[], avoid: string[] = []) {
  const printable: string[] = [];
  for (let code = 0x20; code <= 0x7e; code++) {
    const key = String.fromCharCode(code);
    if (!avoid.includes(key)) printable.push(key);
  }
  return weighted([
    [20, typeFromSet(CharSet.fromLiterals(...printable))],
    [2, typeFromSet(CharSets.UNICODE_SAFE)],
    [4, typeFromSet(CharSets.CONTROL_COMMON)],
    [3, typeFromSet(CharSets.CONTROL_ARROWS)],
    [8, typeFromSet(CharSet.fromLiterals("\x1b"))],
    [6, typeFromSet(CharSet.fromLiterals(...prefixes))],
    [1, { Resize: { rows: [16, 60], columns: [80, 160] } }],
  ]);
}
