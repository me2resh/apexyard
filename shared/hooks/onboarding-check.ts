#!/usr/bin/env bun
/**
 * onboarding-check hook — auto-generated wrapper.
 *
 * Wraps the original bash implementation in .claude/hooks/onboarding-check.sh as an
 * OpenCode TypeScript plugin. The bash logic is the source of truth (100%
 * preserved); this wrapper just shells out to it and bridges the JSON I/O.
 *
 * The _adapter translates between OpenCode's plugin format
 * (lowercase tool, camelCase args) and Claude Code's bash-hook input
 * format (capitalized tool, snake_case args) so the existing rules
 * work as-is.
 *
 * OpenCode plugin event: tool.execute.before
 */

import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { join } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"
import { toClaudeInput } from "./_adapter.ts"

const REPO_ROOT = join(import.meta.dir, "..", "..")
const BASH_SCRIPT = join(REPO_ROOT, ".claude", "hooks", "onboarding-check.sh")

function runBashHook(tool: string, args: Record<string, any>): { ok: boolean; stderr: string } {
  if (!existsSync(BASH_SCRIPT)) {
    return { ok: true, stderr: `[onboarding-check] bash script not found, skipping` }
  }
  const payload = JSON.stringify(toClaudeInput(tool, args))
  const result = spawnSync("bash", [BASH_SCRIPT], {
    input: payload,
    encoding: "utf-8",
    maxBuffer: 50 * 1024 * 1024,
  })
  if (result.status === 0) return { ok: true, stderr: "" }
  if (result.status === 2) {
    return { ok: false, stderr: result.stderr || "blocked" }
  }
  return { ok: true, stderr: result.stderr }
}

const onboarding_check: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      const r = runBashHook(input.tool, output.args || {})
      if (!r.ok) {
        throw new Error(`BLOCKED by onboarding-check hook:\n${r.stderr}`)
      }
    },
  }
}

export default onboarding_check
