#!/usr/bin/env bun
/**
 * validate-branch-name hook
 *
 * Enforces branch naming convention: {type}/{TICKET-ID}-{description}
 * Types: feature, fix, refactor, chore, docs, test, spike, ci, build, perf
 * Mirrors .claude/hooks/validate-branch-name.sh
 */

import { execSync } from "node:child_process"
import type { Plugin } from "@opencode-ai/plugin"

const TYPES = ["feature", "fix", "refactor", "chore", "docs", "test", "spike", "ci", "build", "perf"]
const TICKET_PATTERN = /^(#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+)$/
const BRANCH_REGEX = /^(feature|fix|refactor|chore|docs|test|spike|ci|build|perf)\/((?:#[0-9]+|GH-[0-9]+|[A-Z]{2,10}-[0-9]+))-[a-z0-9][a-z0-9-]*$/

const validateBranchName: Plugin = async ({ directory }) => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const cmd = (output.args?.command as string) || ""
      // Only check on push, on switch (post-creation), or first commit per session
      if (!/^git\s+(push|checkout\s+-b|switch\s+-c)\b/.test(cmd.trim())) return
      let branch = ""
      try {
        branch = execSync("git symbolic-ref --short HEAD", { cwd: directory, encoding: "utf-8" }).trim()
      } catch {
        return
      }
      if (!BRANCH_REGEX.test(branch)) {
        const m = branch.match(/^([^/]+)\/(.+)$/)
        const typeOk = m && TYPES.includes(m[1])
        const ticketOk = m && TICKET_PATTERN.test(m[2].split("-")[0])
        if (!typeOk || !ticketOk) {
          throw new Error(
            `BLOCKED: Branch name '${branch}' doesn't match convention.\n` +
              `Expected: {type}/{TICKET-ID}-{description}\n` +
              `Types: ${TYPES.join(", ")}\n` +
              `Example: feature/GH-42-add-csv-export`,
          )
        }
      }
    },
  }
}

export default validateBranchName
