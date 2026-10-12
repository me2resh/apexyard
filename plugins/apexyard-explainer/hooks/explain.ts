// Pure templates and helpers. No engine calls.
export const MAX_WORDS = 15

export function wordCount(line: string): number {
  return line.split(/\s+/).filter(Boolean).length
}

export const TEMPLATES: Readonly<Record<string, string>> = {
  read: "Reads the file {file} to learn the code.",
  edit: "Edits the file {file} to change the code.",
  write: "Writes the file {file} to save new content.",
  grep: "Searches the code for {pattern} to find where it appears.",
  glob: "Looks for files that match {pattern} to find the right ones.",
  agent: "Asks the {agent} agent to do one part of the work.",
  agentAny: "Asks a helper agent to do one part of the work.",
  agentReview: "Asks a reviewer agent to check the PR.",
  skill: "Runs the skill {skill} to follow its steps.",
  webFetch: "Reads a web page to get facts for the task.",
  webSearch: "Searches the web to find facts for the task.",
  todo: "Updates the task list to track the work.",
  ask: "Asks you a question to choose the next step.",
  unknown: "Runs the tool `{tool}`.",
  tests: "Runs the tests to check the change.",
  gitStatus: "Checks git status to see what changed.",
  gitDiff: "Shows the git diff to review the changes.",
  gitLog: "Reads the git log to learn the recent history.",
  gitAdd: "Adds files to the next commit to prepare it.",
  gitCommit: "Makes a git commit to save the change.",
  gitPush: "Pushes the branch to share the change.",
  gitFetch: "Gets new commits from the remote to stay current.",
  gitBranch: "Changes or lists git branches to keep work apart.",
  gitWorktree: "Makes or removes a separate work folder for the task.",
  git: "Runs a git command to manage the code history.",
  ghPrCreate: "Opens a pull request so others can review the change.",
  ghPrMerge: "Merges the pull request to finish the change.",
  ghPrReview: "Adds a review or comment on the pull request.",
  ghPr: "Reads the pull request to check its status.",
  ghIssueCreate: "Opens a new issue to track the work.",
  ghIssue: "Reads the issue to learn what to build.",
  gh: "Runs a GitHub command to work with the repository.",
  bash: "Runs a shell command to do one step of the task.",
}

export function fill(template: string, values: Record<string, string>): string {
  return template.replace(/\{(file|pattern|agent|skill|tool)\}/g, (_, key: string) => values[key] ?? '?')
}

export function token(value: unknown, max = 32): string {
  if (typeof value !== 'string' || !value.trim()) return '?'
  const trimmed = value.trim()
  const first = trimmed.split(/\s+/)[0] ?? ''
  const limit = Math.max(1, max)
  const shortened = first.length < trimmed.length ? `${first}…` : first
  return shortened.length > limit ? `${shortened.slice(0, limit - 1)}…` : shortened
}

export function baseName(path: unknown): string {
  return token(typeof path === 'string' ? path.split(/[\/\\]/).pop() : path)
}

export type BashKind = 'tests' | 'gitStatus' | 'gitDiff' | 'gitLog' | 'gitAdd' |
  'gitCommit' | 'gitPush' | 'gitFetch' | 'gitBranch' | 'gitWorktree' | 'git' |
  'ghPrCreate' | 'ghPrMerge' | 'ghPrReview' | 'ghPr' | 'ghIssueCreate' | 'ghIssue' | 'gh' | 'bash'

const TEST_RUNS = [
  'npm test', 'npm run test', 'pnpm test', 'pnpm run test', 'yarn test',
  'bun test', 'npx jest', 'npx vitest', 'jest', 'vitest', 'pytest',
  'python -m pytest', 'python3 -m pytest', 'go test', 'cargo test',
  'bats', 'make test', 'claude plugin test',
].map(run => run.split(' '))

export function bashKind(command: string): BashKind {
  const segments = command.split(/&&|\|\||;|\||\n/).map(segment => {
    const words = segment.trim().split(/\s+/).filter(Boolean)
    while (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0] ?? '')) words.shift()
    return words
  }).filter(words => words.length && !['cd', 'export', 'set', 'source', '.', 'echo', 'true', 'sleep'].includes(words[0] ?? ''))
  if (segments.some(words => TEST_RUNS.some(run => run.every((word, i) => words[i] === word)) ||
    words.some(word => /(?:\.bats|test\.sh)$/.test(word)))) return 'tests'
  const words = segments[0] ?? []
  if (words[0] === 'git') {
    let i = 1
    while (i < words.length) {
      const word = words[i] ?? ''
      if (word === '-C' || word === '-c') i += 2
      else if (word === '--no-pager' || /^(--git-dir|--work-tree)=/.test(word)) i++
      else break
    }
    const kinds: Readonly<Record<string, BashKind>> = {
      status: 'gitStatus', diff: 'gitDiff', show: 'gitDiff', log: 'gitLog', add: 'gitAdd',
      commit: 'gitCommit', push: 'gitPush', fetch: 'gitFetch', pull: 'gitFetch',
      checkout: 'gitBranch', switch: 'gitBranch', branch: 'gitBranch', worktree: 'gitWorktree',
    }
    return kinds[words[i] ?? ''] ?? 'git'
  }
  if (words[0] === 'gh') {
    const args: string[] = []
    for (let i = 1; i < words.length; i++) {
      if (words[i] === '-R' || words[i] === '--repo') i++
      else args.push(words[i] ?? '')
    }
    if (args[0] === 'pr') {
      if (args[1] === 'create') return 'ghPrCreate'
      if (args[1] === 'merge') return 'ghPrMerge'
      if (args[1] === 'review' || args[1] === 'comment') return 'ghPrReview'
      return 'ghPr'
    }
    if (args[0] === 'issue') return args[1] === 'create' ? 'ghIssueCreate' : 'ghIssue'
    return 'gh'
  }
  return 'bash'
}

export function explain(tool: string, input: Readonly<Record<string, unknown>>): string {
  let key: string
  const values: Record<string, string> = {}
  switch (tool) {
    case 'Read': case 'Edit': case 'Write': case 'MultiEdit': case 'NotebookEdit':
      key = tool === 'Read' ? 'read' : tool === 'Write' ? 'write' : 'edit'
      values.file = baseName(tool === 'NotebookEdit' ? input.notebook_path : input.file_path)
      break
    case 'Grep': case 'Glob':
      key = tool === 'Grep' ? 'grep' : 'glob'
      values.pattern = token(input.pattern)
      break
    case 'Agent': case 'Task':
      if ([input.subagent_type, input.description].some(value => typeof value === 'string' && /review|rex|auditor/i.test(value))) key = 'agentReview'
      else if (typeof input.subagent_type === 'string' && input.subagent_type.trim()) {
        key = 'agent'
        values.agent = token(input.subagent_type)
      } else key = 'agentAny'
      break
    case 'Skill': key = 'skill'; values.skill = token(input.skill); break
    case 'Bash': key = bashKind(String(input.command ?? '')); break
    case 'WebFetch': key = 'webFetch'; break
    case 'WebSearch': key = 'webSearch'; break
    case 'TodoWrite': case 'TaskCreate': case 'TaskUpdate': key = 'todo'; break
    case 'AskUserQuestion': key = 'ask'; break
    default: key = 'unknown'; values.tool = token(tool, 48)
  }
  return fill(TEMPLATES[key] ?? TEMPLATES.unknown ?? 'Runs the tool `{tool}`.', values)
}
