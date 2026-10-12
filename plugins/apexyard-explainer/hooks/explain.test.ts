import { describe, expect, test } from 'claude-code/testing'

import { baseName, bashKind, explain, fill, MAX_WORDS, TEMPLATES, token, wordCount } from './explain'

describe('plain templates', () => {
  test('every template has 15 words or fewer', async () => {
    for (const [key, text] of Object.entries(TEMPLATES)) {
      expect({ key, ok: wordCount(text) <= MAX_WORDS }).toEqual({ key, ok: true })
    }
  })
  test('every template is one sentence', async () => {
    for (const [key, text] of Object.entries(TEMPLATES)) {
      expect({ key, ok: /^[A-Z]/.test(text) && text.endsWith('.') && !/[.?!] /.test(text) }).toEqual({ key, ok: true })
    }
  })
  test('hostile inputs keep filled lines within 15 words', async () => {
    const cases: Array<[string, Record<string, unknown>]> = [
      ['Read', { file_path: '/long path/' + 'a'.repeat(100) + ' file.ts' }],
      ['Edit', { file_path: 'C:\\long path\\some long file.ts' }],
      ['Grep', { pattern: 'many words with spaces and more words' }],
      ['Read', {}], ['x'.repeat(200), {}],
      ['Bash', { command: 'ls ' + 'word '.repeat(100) }],
      ['Grep', { pattern: 'a b c d e f g h i j k l m n o p q r s t' }],
      ['Agent', { subagent_type: 'x y z w v u t s r q p o n m' }],
    ]
    for (const [tool, input] of cases) expect(wordCount(explain(tool, input)) <= MAX_WORDS).toBe(true)
  })
  test('the acceptance tools give exact lines', async () => {
    const cases: Array<[string, Record<string, unknown>, string]> = [
      ['Read', { file_path: '/a/b/app.ts' }, 'Reads the file app.ts to learn the code.'],
      ['Edit', { file_path: '/a/app.ts' }, 'Edits the file app.ts to change the code.'],
      ['Write', { file_path: '/a/app.ts' }, 'Writes the file app.ts to save new content.'],
      ['Grep', { pattern: 'foo bar' }, 'Searches the code for foo… to find where it appears.'],
      ['Glob', { pattern: '*.ts' }, 'Looks for files that match *.ts to find the right ones.'],
      ['Agent', {}, 'Asks a helper agent to do one part of the work.'],
      ['Agent', { subagent_type: 'builder' }, 'Asks the builder agent to do one part of the work.'],
      ['Agent', { subagent_type: 'rex' }, 'Asks a reviewer agent to check the PR.'],
      ['Agent', { description: 'review the change' }, 'Asks a reviewer agent to check the PR.'],
      ['Skill', { skill: 'start-ticket' }, 'Runs the skill start-ticket to follow its steps.'],
      ['mcp__x__y', {}, 'Uses X: y.'],
    ]
    for (const [tool, input, line] of cases) expect(explain(tool, input)).toBe(line)
    expect(explain('MultiEdit', { file_path: 'a.ts' })).toBe(explain('Edit', { file_path: 'a.ts' }))
    expect(explain('NotebookEdit', { notebook_path: 'a.ipynb' })).toBe(TEMPLATES.notebookEdit)
    expect(explain('Task', {})).toBe(TEMPLATES.agentAny)
    const plain: Array<[string, string]> = [['WebFetch', 'webFetch'], ['WebSearch', 'webSearch'], ['TodoWrite', 'todo'], ['TaskCreate', 'todo'], ['TaskUpdate', 'todo'], ['AskUserQuestion', 'ask']]
    for (const [tool, key] of plain) {
      expect(explain(tool, {})).toBe(TEMPLATES[key])
    }
  })
  test('classifies shell commands and test runs', async () => {
    const cases: Array<[string, string]> = [
      ['git status', 'gitStatus'], ['git -C /x commit -m "a b"', 'gitCommit'],
      ['cd /w && git push -u origin x', 'gitPush'], ['gh pr create --title t', 'ghPrCreate'],
      ['gh -R a/b pr merge 3', 'ghPrMerge'], ['gh issue view 1661 -R me2resh/apexyard', 'ghIssue'],
      ['npm test', 'tests'], ['cd plugins && claude plugin test x', 'tests'],
      ['bash tests/foo.bats', 'tests'], ['FOO=1 pytest -q', 'tests'], ['ls -la', 'bash'],
      ['', 'bash'], ['echo hi; git status | pytest', 'tests'],
      ['git --no-pager -c a=b --git-dir=/g --work-tree=/w show', 'gitDiff'],
      ['git log', 'gitLog'], ['git add a', 'gitAdd'], ['git pull', 'gitFetch'],
      ['git switch x', 'gitBranch'], ['git worktree list', 'gitWorktree'], ['git reset', 'git'],
      ['gh pr comment 3', 'ghPrReview'], ['gh pr view 3', 'ghPr'],
      ['gh issue create', 'ghIssueCreate'], ['gh repo view', 'gh'],
      ['true || sleep 1\nexport A=1; set -e; source x; . x; git status', 'gitStatus'],
      ['sh tests/test.sh', 'tests'], ['git status && pnpm run test', 'tests'],
    ]
    for (const [command, key] of cases) {
      expect({ command, key: bashKind(command) }).toEqual({ command, key })
      expect(explain('Bash', { command })).toBe(TEMPLATES[key])
    }
    for (const command of ['npm run test', 'pnpm test', 'yarn test', 'bun test', 'npx jest', 'npx vitest', 'jest', 'vitest', 'python -m pytest', 'python3 -m pytest', 'go test', 'cargo test', 'bats', 'make test']) {
      expect(bashKind(command)).toBe('tests')
    }
  })
  test('tokens, file names and placeholders', async () => {
    expect(wordCount('  a\n b\t ')).toBe(2)
    expect(wordCount('')).toBe(0)
    expect(token(null)).toBe('?')
    expect(token('  ')).toBe('?')
    expect(token(' hello world ')).toBe('hello…')
    expect(token('a'.repeat(40))).toBe('a'.repeat(31) + '…')
    expect(token('abcd', 3)).toBe('ab…')
    expect(token('abc', 3)).toBe('abc')
    expect(baseName('/a/b/app.ts')).toBe('app.ts')
    expect(baseName('C:\\a\\app.ts')).toBe('app.ts')
    expect(baseName('/a/some file.ts')).toBe('some…')
    expect(baseName(undefined)).toBe('?')
    expect(baseName('/')).toBe('?')
    expect(fill('{file} {file} {tool}', { file: 'a' })).toBe('a a ?')
  })
})


describe('fallback order', () => {
  test('safe descriptions win for any tool except a reviewer', async () => {
    for (const tool of ['Bash', 'Agent', 'Task', 'Read', 'Workflow', 'mcp__Gmail__search_threads', 'FutureTool']) {
      expect(explain(tool, { command: 'git status', description: '  Checks\n the next\tstep  ' })).toBe('Checks the next step.')
    }
    expect(explain('Agent', { subagent_type: 'rex', description: 'Checks the change' })).toBe(TEMPLATES.agentReview)
    expect(explain('Task', { description: 'review the change' })).toBe(TEMPLATES.agentReview)
    for (const description of [undefined, null, 42, '', ' \n ']) {
      expect(explain('Bash', { command: 'git status', description })).toBe(TEMPLATES.gitStatus)
    }
    expect(explain('Bash', { description: 'a '.repeat(100) }).length <= 120).toBe(true)
    expect(explain('Bash', { description: 'Reads ' + 'word '.repeat(30) })).toBe(('Reads ' + 'word '.repeat(30)).slice(0, 119).trimEnd() + '.')
    for (const ending of ['.', '!', '?', '...']) {
      expect(explain('Read', { description: 'Reads the file' + ending })).toBe('Reads the file.')
    }
  })
  test('MCP names become server and tool words', async () => {
    expect(explain('mcp__claude_ai_Gmail__search_threads', {})).toBe('Uses Gmail: search threads.')
    expect(explain('mcp__my_server-name__read-file_now', {})).toBe('Uses My Server Name: read file now.')
    expect(explain('mcp__Gmail__search_threads', { description: 'Finds the mail' })).toBe('Finds the mail.')
    expect(explain('mcp__Gmail__', {})).toBe('Runs the tool `mcp__Gmail__`.')
  })
  test('new built-ins have plain templates', async () => {
    const cases: Array<[string, string]> = [
      ['Workflow', 'workflow'], ['ToolSearch', 'toolSearch'], ['SendMessage', 'sendMessage'],
      ['Monitor', 'monitor'], ['TaskStop', 'taskStop'], ['Artifact', 'artifact'], ['LSP', 'lsp'],
      ['NotebookEdit', 'notebookEdit'], ['ScheduleWakeup', 'scheduleWakeup'],
      ['ReadNotifications', 'readNotifications'], ['BashOutput', 'bashOutput'],
      ['TaskOutput', 'bashOutput'], ['task-output', 'bashOutput'], ['task_output', 'bashOutput'],
    ]
    for (const [tool, key] of cases) expect(explain(tool, {})).toBe(TEMPLATES[key])
    expect(explain('FutureTool', {})).toBe('Runs the tool `FutureTool`.')
  })
  test('token-looking descriptions and commands fall back without exposing them', async () => {
    const secrets = ['ghp_' + 'x'.repeat(12), 'sk-' + 'x'.repeat(12), 'xoxb-' + 'x'.repeat(12),
      'abcdef0123456789'.repeat(3), 'QWxhZGRpbjpvcGVuIHNlc2FtZQ'.repeat(2)]
    for (const secret of secrets) {
      expect(explain('Bash', { description: 'Uses ' + secret, command: 'git status' })).toBe(TEMPLATES.gitStatus)
      expect(explain('Bash', { description: 'Checks the change', command: 'git diff ' + secret })).toBe(TEMPLATES.gitDiff)
      expect(explain('Agent', { description: 'Builds with ' + secret })).toBe(TEMPLATES.agentAny)
      expect(explain('mcp__Gmail__search_threads', { description: 'Finds ' + secret })).toBe('Uses Gmail: search threads.')
      expect(explain('Bash', { description: 'word '.repeat(40) + secret })).toBe(TEMPLATES.bash)
    }
  })
})
