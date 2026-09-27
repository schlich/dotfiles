import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";

const webDir = path.dirname(fileURLToPath(import.meta.url));
const repo =
  process.argv.find(
    (argument, index) => process.argv[index - 1] === "--repo",
  ) || process.cwd();
const children = [];

function start(command, args, options = {}) {
  const child = spawn(command, args, { stdio: "inherit", ...options });
  children.push(child);
  child.on("exit", (code) => {
    if (code && code !== 0) stop(code);
  });
  return child;
}

function stop(code = 0) {
  for (const child of children) if (!child.killed) child.kill("SIGTERM");
  process.exitCode = code;
}

process.on("SIGINT", () => stop(0));
process.on("SIGTERM", () => stop(0));
start("python3", [
  path.resolve(webDir, "../server.py"),
  "--repo",
  path.resolve(repo),
]);
start("pnpm", ["exec", "iwsdk", "dev", "up", "--open", "--foreground"], {
  cwd: webDir,
});
