#!/usr/bin/env bun
/**
 * verify-commit-refs hook — auto-generated wrapper.
 *
 * Wraps the original bash implementation in .claude/hooks/verify-commit-refs.sh as an
 * OpenCode TypeScript plugin. The bash logic is the source of truth (100%
 * preserved); this wrapper just shells out to it and bridges the JSON I/O.
 *
 * OpenCode plugin event: tool.execute.before
 */

import { spawnSync } from "node:child_process"
import { existsSync } from "node:fs"
import { join, dirname } from "node:path"
import type { Plugin } from "@opencode-ai/plugin"

const REPO_ROOT = join(import.meta.dir, "..", "..")
const BASH_SCRIPT = join(REPO_ROOT, ".claude", "hooks", "verify-commit-refs.sh")

interface BashInput {
  tool: string
  args: Record<string, any>
}

function runBashHook(input: BashInput): { ok: boolean; stderr: string } {
  if (!existsSync(BASH_SCRIPT)) {
    return { ok: true, stderr: `[verify-commit-refs] bash script not found, skipping` }
  }
  const payload = JSON.stringify({ tool_name: input.tool, tool_input: input.args })
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

const verify_commit_refs: Plugin = async () => {
  return {
    "tool.execute.before": async (input, output) => {
      const r = runBashHook({ tool: input.tool, args: output.args || {} })
      if (!r.ok) {
        throw new Error(`BLOCKED by verify-commit-refs hook:\n${r.stderr}`)
      }
    },
  }
}

export default verify_commit_refs
