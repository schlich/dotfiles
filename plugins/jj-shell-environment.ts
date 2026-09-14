import type { Plugin } from "@opencode-ai/plugin"

export default (async () => ({
  "shell.env": async (_input, output) => {
    output.env.JJ_EDITOR = "true"
    output.env.PAGER = "cat"
  },
})) satisfies Plugin
