import type { EngineInterface } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'
import { inFlightText } from './orbit'
import { ghJson, namesSlice, parseRegistry, processPool, register, snapshot } from './register'

describe('pane lookups', () => {
  test('matches exact slice IDs and parses the registry', () => {
    expect(namesSlice('ORBIT: `slice-t1`', 'slice-t1')).toBe(true)
    expect(namesSlice('slice-t10 slice-t1-more', 'slice-t1')).toBe(false)
    expect(parseRegistry('projects:\n  - name: one\n    repo: a/b\n    workspace: workspace/b\n  - name: two\n    repo: a/c\n    workspace: workspace/c')).toEqual([
      { repo: 'a/b', workspace: 'workspace/b' }, { repo: 'a/c', workspace: 'workspace/c' },
    ])
  })
  test('missing gh and failed queries are offline and cached with the band limits', async () => {
    let calls = 0
    let now = 1000
    // Minimal engine stub for this read-only boundary.
    const engine = {
      clock: { now: async () => now },
      process: { run: async (argv: string[], options: { timeoutMs: number }) => {
        calls++
        expect(argv[0]).toBe('gh')
        expect(options.timeoutMs).toBe(5000)
        if (calls === 1) throw new Error('gh missing')
        return { exitCode: 1, stdout: '' }
      } },
    } as unknown as EngineInterface
    const query = ['search', 'issues', 'offline-test']
    expect(await ghJson(engine, query)).toBe(null)
    expect(await ghJson(engine, query)).toBe(null)
    expect(calls).toBe(1)
    now += 120000
    expect(await ghJson(engine, query)).toBe(null)
    expect(calls).toBe(2)
  })
})

test('process pool never exceeds four concurrent calls, including failures', async () => {
  const pool = processPool(4)
  let active = 0, maximum = 0
  const releases: (() => void)[] = []
  const jobs = Array.from({ length: 12 }, (_, i) => pool(async () => {
    active++
    maximum = Math.max(maximum, active)
    await new Promise<void>(resolve => releases.push(resolve))
    active--
    if (i === 2) throw new Error('offline')
  }).catch(() => {}))
  for (let i = 0; i < 20; i++) {
    await Promise.resolve()
    releases.splice(0).forEach(release => release())
  }
  await Promise.all(jobs)
  expect(maximum).toBe(4)
  expect(active).toBe(0)
})

test('registration and headless lifecycle perform no engine operations', async () => {
  type Hook = (engine: EngineInterface, event: never, next: (event: never) => Promise<string>) => Promise<unknown>
  const hooks = new Map<string, Hook>()
  const on = ((event: string, filter: unknown, handler?: Hook) => {
    if (event === 'session.start' || event === 'turn.complete') hooks.set(event, (handler ?? filter) as Hook)
  }) as unknown as import('claude-code').On
  let operations = 0
  const engine = new Proxy({}, { get() { operations++; throw new Error('headless engine accessed') } }) as EngineInterface
  register(on, {})
  expect(operations).toBe(0)
  for (const event of ['session.start', 'turn.complete', 'turn.complete']) {
    expect(await hooks.get(event)!(engine, {} as never, async () => 'continued')).toBe('continued')
  }
  expect(operations).toBe(0)
})

test('interactive startup and turn completion return while lookups remain pending', async () => {
  type Hook = (engine: EngineInterface, event: never, next: (event: never) => Promise<string>) => Promise<unknown>
  const hooks = new Map<string, Hook>()
  const on = ((event: string, filter: unknown, handler?: Hook) => {
    if (event !== 'ui.render' || (filter as { component?: string }).component === 'Pane') hooks.set(event + (typeof filter === 'object' ? '/ui' : ''), (handler ?? filter) as Hook)
  }) as unknown as import('claude-code').On
  let timers = 0, lookups = 0
  const engine = {
    clock: { every: () => { timers++ } },
    command: { register: async () => {} },
    session: { cwd: () => { lookups++; return new Promise<string>(() => {}) } },
  } as unknown as EngineInterface
  register(on, {})
  expect(await hooks.get('session.start')!(engine, {} as never, async () => 'ready')).toBe('ready')
  expect(lookups).toBe(0)
  await hooks.get('ui.render/ui')!(engine, {} as never, async () => 'rendered').catch(() => {})
  expect(await hooks.get('turn.complete')!(engine, {} as never, async () => 'returned')).toBe('returned')
  expect(timers).toBe(1)
  expect(lookups).toBe(1)
})


test('a timed-out gh call returns offline and releases its process slot', async () => {
  let calls = 0
  const engine = {
    clock: { now: async () => 0 },
    process: { run: async (_argv: string[], options: { timeoutMs: number }) => {
      expect(options.timeoutMs).toBe(5000)
      calls++
      throw new Error('process timed out after 5000ms')
    } },
  } as unknown as EngineInterface
  const results = await Promise.all(Array.from({ length: 8 }, (_, i) => ghJson(engine, ['timeout-test', String(i)])))
  expect(calls).toBe(8)
  expect(results.every(result => result === null)).toBe(true)
  expect(inFlightText([{ status: 'error', issues: [] }])).toBe('in flight (offline)')
})


test('one git snapshot reads records and notes together', async () => {
  let calls = 0
  const engine = { process: { run: async (argv: string[]) => {
    calls++
    expect(argv).toEqual(['git', '-C', '/repo', 'grep', '--no-color', '-I', '-e', '^', 'origin/dev', '--', 'docs/orbit'])
    return { exitCode: 0, stdout: 'origin/dev:docs/orbit/plans/p.json:{\norigin/dev:docs/orbit/plans/p.json:"id":"p"}\norigin/dev:docs/orbit/plans/p.notes.md:## Checks\n' }
  } } } as unknown as EngineInterface
  const files = await snapshot(engine, '/repo', 'dev')
  expect(calls).toBe(1)
  expect(JSON.parse(files.get('docs/orbit/plans/p.json')!)).toEqual({ id: 'p' })
  expect(files.get('docs/orbit/plans/p.notes.md')).toBe('## Checks\n')
})
