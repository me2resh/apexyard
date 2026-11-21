import { describe, expect, test } from 'claude-code/testing'

import {
  APPROVE_LABEL,
  approvalQuestion,
  approveFlow,
  blocker,
  candidatesFrom,
  ciState,
  NOT_YET_LABEL,
  parsePrView,
  recordSha,
  rexVerdict,
} from './approve'
import type { Deps, PrView, Shown } from './approve'

const SHA = 'abcdef1234567890abcdef1234567890abcdef12'
const MOVED = '0123456789abcdef0123456789abcdef01234567'
const ROW: Shown = { repo: 'me2resh/apexyard', number: 1683, head: SHA, rexSha: SHA, ci: 'pass', open: true }
const LIVE: PrView = { open: true, head: SHA, title: 't', ci: 'pass' }
const RECORD = `sha=${SHA}\napproved_by=user\nskill_version=3\n`

// A fake engine boundary that counts every question asked.
function deps(over: Partial<Deps> & { answer?: string | Error; record?: string | null; live?: PrView | null } = {}) {
  const asked: { question: string; options: readonly string[] }[] = []
  const d: Deps = {
    lookup: async () => (over.live === undefined ? LIVE : over.live),
    ask: async (question, options) => {
      asked.push({ question, options })
      if (over.answer instanceof Error) throw over.answer
      return over.answer ?? APPROVE_LABEL
    },
    readRecord: async () => (over.record === undefined ? RECORD : over.record),
    sleep: async () => {},
    ...over,
  }
  return { d, asked }
}

describe('question shape', () => {
  test('matches the AgDR-0234 merge shape for the exact SHA', () => {
    expect(approvalQuestion('me2resh/apexyard', 1683, SHA)).toBe(`Approve and merge me2resh/apexyard#1683 at ${SHA}?`)
    expect(APPROVE_LABEL).toBe('Approve and merge')
    expect(NOT_YET_LABEL).toBe('Not yet')
  })
})

describe('stale SHA', () => {
  test('refuses and asks nothing when the head moved after the pane drew', async () => {
    const { d, asked } = deps({ live: { ...LIVE, head: MOVED } })
    const out = await approveFlow(d, ROW)
    expect(out.kind).toBe('stale')
    expect(asked.length).toBe(0)
  })
  test('refuses and asks nothing when Rex reviewed another head', async () => {
    const { d, asked } = deps()
    const out = await approveFlow(d, { ...ROW, rexSha: MOVED })
    expect(out.kind).toBe('refused')
    expect(asked.length).toBe(0)
  })
  test('refuses when the PR closed, gh fails, or CI fails', async () => {
    for (const live of [{ ...LIVE, open: false }, null, { ...LIVE, ci: 'fail' as const }]) {
      const { d, asked } = deps({ live })
      expect((await approveFlow(d, ROW)).kind).toBe('refused')
      expect(asked.length).toBe(0)
    }
  })
  test('warns when the head moved while the menu was open', async () => {
    let calls = 0
    const { d } = deps({ lookup: async () => (++calls === 1 ? LIVE : { ...LIVE, head: MOVED }) })
    const out = await approveFlow(d, ROW)
    expect(out.kind).toBe('recorded')
    expect(out.note).toContain('merge gate will refuse')
  })
})

describe('human key press', () => {
  test('a dismissed menu or a session with nobody to ask records nothing', async () => {
    const { d, asked } = deps({ answer: new Error('dismissed') })
    const out = await approveFlow(d, ROW)
    expect(asked.length).toBe(1)
    expect(out.kind).toBe('no-answer')
  })
  test('Not yet and free text record nothing', async () => {
    for (const answer of [NOT_YET_LABEL, 'go', 'approve']) {
      const { d } = deps({ answer, record: null })
      expect((await approveFlow(d, ROW)).kind).toBe('not-yet')
    }
  })
  test('the exact approve label asks once and reads back the hook record', async () => {
    const { d, asked } = deps()
    const out = await approveFlow(d, ROW)
    expect(asked).toEqual([{ question: approvalQuestion(ROW.repo, ROW.number, SHA), options: [APPROVE_LABEL, NOT_YET_LABEL] }])
    expect(out.kind).toBe('recorded')
  })
  test('reports when the hook wrote no record, or a record for another SHA', async () => {
    for (const record of [null, `sha=${MOVED}\n`]) {
      const { d } = deps({ record })
      expect((await approveFlow(d, ROW)).kind).toBe('not-recorded')
    }
  })
})

describe('row data', () => {
  test('reads CI words from the check rollup', () => {
    expect(ciState([])).toBe('none')
    expect(ciState(null)).toBe('unknown')
    expect(ciState([{ status: 'COMPLETED', conclusion: 'SUCCESS' }, { state: 'SUCCESS' }])).toBe('pass')
    expect(ciState([{ status: 'IN_PROGRESS', conclusion: '' }])).toBe('pending')
    expect(ciState([{ state: 'PENDING' }])).toBe('pending')
    expect(ciState([{ status: 'IN_PROGRESS' }, { status: 'COMPLETED', conclusion: 'FAILURE' }])).toBe('fail')
  })
  test('parses gh pr view and refuses a short head', () => {
    expect(parsePrView(JSON.stringify({ state: 'OPEN', headRefOid: SHA, title: 'x', statusCheckRollup: [] }))).toEqual({ open: true, head: SHA, title: 'x', ci: 'none' })
    expect(parsePrView(JSON.stringify({ state: 'OPEN', headRefOid: 'abc' }))).toBe(null)
    expect(parsePrView('not json')).toBe(null)
  })
  test('lists Rex markers with no CEO marker inside the window', () => {
    const now = 10 * 86400000
    const out = candidatesFrom([
      { name: 'me2resh__apexyard__1-rex.approved', mtimeMs: now },
      { name: 'me2resh__apexyard__2-rex.approved', mtimeMs: now },
      { name: 'me2resh__apexyard__2-ceo.approved', mtimeMs: now },
      { name: 'me2resh__apexyard__3-rex.approved', mtimeMs: 0 },
    ], now, 3)
    expect(out.map(c => c.number)).toEqual([1])
  })
  test('reads the record SHA and the Rex verdict', () => {
    expect(recordSha(RECORD)).toBe(SHA)
    expect(recordSha(SHA)).toBe(null)
    expect(rexVerdict({ rexSha: SHA, head: SHA })).toBe('Rex: approved at abcdef1')
    expect(rexVerdict({ rexSha: MOVED, head: SHA })).toContain('re-review')
    expect(blocker(ROW)).toBe(null)
    expect(blocker({ ...ROW, open: null })).not.toBe(null)
  })
})
