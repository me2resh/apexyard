#!/usr/bin/env bun
/**
 * Hook I/O adapter — bridges OpenCode's plugin event format and the
 * legacy Claude Code bash-hook input format.
 *
 * OpenCode plugin format (from `tool.execute.before` event):
 *   input.tool    = "bash"  (lowercase)
 *   output.args   = { command, filePath, ... }  (camelCase)
 *
 * Claude Code bash-hook input format (consumed by all .claude/hooks/*.sh):
 *   tool_name     = "Bash"  (capitalized)
 *   tool_input    = { command, file_path, ... }  (snake_case)
 *
 * The bash hook is the source of truth for the rules (100% preserved).
 * The TS wrapper calls this adapter, shells out to the bash script, and
 * translates the exit code into a thrown error to block the tool call.
 */

/**
 * Capitalize the first letter of a tool name.
 * `bash` → `Bash`, `edit` → `Edit`, `write` → `Write`, `read` → `Read`
 */
function capitalize(s: string): string {
  if (!s) return s
  return s.charAt(0).toUpperCase() + s.slice(1)
}

/**
 * Convert a single camelCase key to snake_case.
 * `filePath` → `file_path`, `multiEdit` → `multi_edit`, `command` → `command`
 */
function camelToSnake(key: string): string {
  return key.replace(/([A-Z])/g, "_$1").toLowerCase()
}

/**
 * Recursively transform object keys from camelCase to snake_case.
 * Values are left as-is (primitives, arrays, nested objects all preserved).
 */
function camelArgsToSnake(args: Record<string, any>): Record<string, any> {
  if (!args || typeof args !== "object") return args
  const out: Record<string, any> = {}
  for (const [k, v] of Object.entries(args)) {
    const newKey = camelToSnake(k)
    if (v && typeof v === "object" && !Array.isArray(v)) {
      out[newKey] = camelArgsToSnake(v)
    } else {
      out[newKey] = v
    }
  }
  return out
}

/**
 * Adapt an OpenCode `tool.execute.before` event into a Claude Code
 * bash-hook input payload.
 */
export function toClaudeInput(
  toolName: string,
  args: Record<string, any>,
): { tool_name: string; tool_input: Record<string, any> } {
  return {
    tool_name: capitalize(toolName),
    tool_input: camelArgsToSnake(args || {}),
  }
}
