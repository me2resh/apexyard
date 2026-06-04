#!/usr/bin/env bun
/**
 * block-main-push hook
 *
 * Blocks `git push` to protected branches (main, master, dev, develop).
 * Mirrors .claude/hooks/block-main-push.sh
 */

import type { Plugin } from "@opencode-ai/plugin"

const PROTECTED = ["main", "master", "dev", "develop"]

const blockMainPush: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const cmd = (output.args?.command as string) || ""
      if (!/^git\s+push\b/.test(cmd.trim())) return
      const m = cmd.match(/^git\s+push\s+(?:-[a-z]+\s+)*([^\s]+)\s+([^\s:]+)/)
      if (!m) return
      const remote = m[1]
      const branch = m[2].replace(/^:/, "")
      if (PROTECTED.includes(branch)) {
        throw new Error(
          `BLOCKED: Direct push to protected branch '${branch}' is not allowed.\n` +
            `All changes must go through a PR. Use: git push ${remote} feature/<branch>`,
        )
      }
    },
  }
}

export default blockMainPush
