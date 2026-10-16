// `ci tower . --json` over the fake world, one step further each call.
import { chance, createLocal, load, save, step, tower } from "./world.mjs";

const args = process.argv.slice(2);
if (args[0] !== "tower") {
  process.stderr.write(`fake ci: no ${args.join(" ")}\n`);
  process.exit(2);
}
const world = load("local.json", createLocal);
const first = world.tick === 0;
step(world);
// The tower is sometimes unreachable, but never on the first call, so the
// server always has a snapshot to keep serving, marked stale.
const unreachable = !first && chance(world, 0.12);
save("local.json", world);
if (unreachable) {
  process.stderr.write(
    "ci tower: another ci command holds the repository lock\n",
  );
  process.exit(1);
}
process.stdout.write(JSON.stringify(tower(world)));
