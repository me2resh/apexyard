#!/usr/bin/env bun
/**
 * require-active-ticket hook
 *
 * Blocks Edit/Write/Bash on code paths when no active ticket marker exists.
 * Mirrors the Claude Code version: .claude/hooks/require-active-ticket.sh
 *
 * Active tickets are declared by the /start-ticket skill. Marker layout:
 *   <ops_root>/.claude/session/tickets/<project>   ← per-project
 *   <ops_root>/.claude/session/current-ticket      ← ops-repo / fallback
 *
 * Resolution order for a given FILE_PATH:
 *   1. If FILE_PATH is under workspace/<project>/, look up
 *      .claude/session/tickets/<project>. If present → exempt.
 *   2. Fall back to .claude/session/current-ticket. If present → exempt.
 *   3. Otherwise, block.
 *
 * Exempt paths (no ticket required):
 *   - .claude/, docs/, *.md
 *   - Anything under projects/*/docs/
 */

import { existsSync, readFileSync } from "node:fs"
import { resolve, relative, join } from "node:path"
import { execSync } from "node:child_process"
import type { Plugin } from "@opencode-ai/plugin"

const EXEMPT_PATTERNS = [
  /(^|\/)\.claude(\/|$)/,
  /(^|\/)docs(\/|$)/,
  /\.md$/,
]

function isExempt(path: string): boolean {
  if (!path) return false
  for (const pat of EXEMPT_PATTERNS) {
    if (pat.test(path)) return true
  }
  return false
}

function getRepoRoot(cwd: string): string {
  try {
    return execSync("git rev-parse --show-toplevel", { cwd, encoding: "utf-8" }).trim()
  } catch {
    return cwd
  }
}

function findOpsRoot(start: string): string {
  let r = start
  while (r && r !== "/") {
    if (
      existsSync(join(r, ".apexyard-fork")) ||
      (existsSync(join(r, "onboarding.yaml")) && existsSync(join(r, "apexyard.projects.yaml")))
    ) {
      return r
    }
    const parent = resolve(r, "..")
    if (parent === r) break
    r = parent
  }
  return start
}

function activeTicketExists(opsRoot: string, filePath: string): { ok: boolean; reason?: string } {
  const workspace = join(opsRoot, "workspace")
  let project = ""
  if (filePath.startsWith(workspace + "/")) {
    const tail = filePath.slice(workspace.length + 1)
    project = tail.split("/")[0]
  }
  if (project) {
    const perProject = join(opsRoot, ".claude/session/tickets", project)
    if (existsSync(perProject)) return { ok: true }
  }
  const fallback = join(opsRoot, ".claude/session/current-ticket")
  if (existsSync(fallback)) return { ok: true }
  return { ok: false, reason: `No active ticket at ${opsRoot}/.claude/session/` }
}

const requireActiveTicket: Plugin = async ({ directory, worktree }) => {
  const opsRoot = findOpsRoot(getRepoRoot(directory))
  return {
    "tool.execute.before": async (input, output) => {
      const tool = input.tool
      if (tool !== "edit" && tool !== "write" && tool !== "bash") return
      let filePath = ""
      if (tool === "bash") {
        const cmd = (output.args?.command as string) || ""
        if (!/(^|\s|=|;|>)\s*(tee|sed\s+-i|cat\s*>>|cat\s*>|echo\s*>>|echo\s*>|>\s*\S+)/.test(cmd)) {
          return
        }
        const m = cmd.match(/(?:tee|sed\s+-i[^\s]*\s+|--output[^\s]*\s+|>\s*)([^\s;|&]+)/)
        if (m) filePath = m[1]
      } else {
        filePath = (output.args?.filePath as string) || (output.args?.path as string) || ""
      }
      if (isExempt(filePath)) return
      const absPath = filePath.startsWith("/") ? filePath : join(directory, filePath)
      const check = activeTicketExists(opsRoot, absPath)
      if (!check.ok) {
        throw new Error(
          `BLOCKED: ${check.reason}\n\nApexYard requires a ticket BEFORE any code changes.\n` +
            `Run /start-ticket <issue-number> to declare one.`,
        )
      }
    },
  }
}

export default requireActiveTicket
