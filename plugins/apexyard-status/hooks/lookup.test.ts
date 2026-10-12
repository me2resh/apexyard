import type { EngineInterface } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'
import { ghJson, namesSlice, parseRegistry } from './register'

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
