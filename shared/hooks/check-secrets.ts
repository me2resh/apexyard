#!/usr/bin/env bun
/**
 * check-secrets hook
 *
 * Scans staged files for common secret patterns (API keys, tokens, passwords)
 * before `git commit`. Blocks the commit if any pattern matches.
 * Mirrors .claude/hooks/check-secrets.sh
 */

import { execSync } from "node:child_process"
import type { Plugin } from "@opencode-ai/plugin"

const PATTERNS: { name: string; regex: RegExp }[] = [
  { name: "AWS access key", regex: /AKIA[0-9A-Z]{16}/ },
  { name: "AWS secret key", regex: /aws_secret_access_key\s*=\s*["'][A-Za-z0-9/+=]{40}["']/i },
  { name: "GitHub token", regex: /gh[pousr]_[A-Za-z0-9]{36,}/ },
  { name: "OpenAI key", regex: /sk-[A-Za-z0-9]{20,}/ },
  { name: "Generic API key", regex: /(?:api[_-]?key|apikey)\s*[:=]\s*["'][A-Za-z0-9_\-]{20,}["']/i },
  { name: "Private key block", regex: /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/ },
  { name: "Slack token", regex: /xox[abposr]-[A-Za-z0-9-]{10,}/ },
  { name: "Stripe key", regex: /sk_(?:live|test)_[A-Za-z0-9]{24,}/ },
  { name: "Google API key", regex: /AIza[0-9A-Za-z\-_]{35}/ },
]

const checkSecrets: Plugin = async ({ directory }) => {
  return {
    "tool.execute.before": async (input, output) => {
      if (input.tool !== "bash") return
      const cmd = (output.args?.command as string) || ""
      if (!/^git\s+commit\b/.test(cmd.trim())) return
      let diff = ""
      try {
        diff = execSync("git diff --cached --diff-filter=ACMR", {
          cwd: directory,
          encoding: "utf-8",
          maxBuffer: 50 * 1024 * 1024,
        })
      } catch (e: any) {
        return
      }
      if (!diff) return
      const findings: string[] = []
      for (const { name, regex } of PATTERNS) {
        if (regex.test(diff)) findings.push(name)
      }
      if (findings.length > 0) {
        throw new Error(
          `BLOCKED: Possible secrets detected in staged changes:\n  - ${findings.join("\n  - ")}\n\n` +
            `Move secrets to env vars or a secrets manager, or use a skip marker.`,
        )
      }
    },
  }
}

export default checkSecrets
