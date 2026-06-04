#!/usr/bin/env bun
/**
 * block-git-add-all hook
 *
 * Blocks `git add -A` and `git add .` (no specific path). Forces explicit staging.
 * Mirrors .claude/hooks/block-git-add-all.sh
 */

import type { Plugin } from "@opencode-ai/plugin"

const blockGitAddAll: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const cmd = (output.args?.command as string) || ""
      const trimmed = cmd.trim()
      if (!/^git\s+add\b/.test(trimmed)) return
      const argPart = trimmed.replace(/^git\s+add\s+/, "")
      if (/^-A\b|^--all\b|\.\s*$|\.\s+/.test(argPart) && !/\S+\s+\S+/.test(argPart.replace(/^-A\s*|^--all\s*|\.\s*$/g, ""))) {
        throw new Error(
          `BLOCKED: 'git add -A' / 'git add .' is not allowed.\n` +
            `Stage specific files: git add path/to/file`,
        )
      }
    },
  }
}

export default blockGitAddAll
