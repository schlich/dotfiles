import { execFile } from "node:child_process"
import { promisify } from "node:util"
import type { Plugin } from "@opencode-ai/plugin"

const execFileAsync = promisify(execFile)
const changes = new Map<string, string>()

async function jj(directory: string, args: string[]) {
  return (await execFileAsync("jj", args, { cwd: directory })).stdout
}

async function isMainChange(directory: string) {
  try {
    const bookmarks = await jj(directory, [
      "bookmark",
      "list",
      "--revision",
      "@",
      "--template",
      "name ++ \"\\n\"",
    ])
    return bookmarks.split("\n").includes("main")
  } catch {
    return false
  }
}

export default (async ({ directory }) => {
  return {
    "tool.execute.before": async (input) => {
      if (!new Set(["edit", "write"]).has(input.tool) || !(await isMainChange(directory))) return

      const bookmark = `opencode/${input.sessionID}`
      await jj(directory, ["new", "-m", "OpenCode changes"])
      changes.set(input.callID, bookmark)
    },
    "tool.execute.after": async (input) => {
      const bookmark = changes.get(input.callID)
      if (!bookmark) return

      await jj(directory, ["bookmark", "create", bookmark, "--revision", "@"]) 
      changes.delete(input.callID)
    },
  }
}) satisfies Plugin
