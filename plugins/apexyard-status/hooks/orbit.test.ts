import { describe, expect, test } from 'claude-code/testing'

import { checksDate, inFlightText, bandText, bar, clip, mergeRecords, pickPlan, pickReconciliation, shortLabel, splitShownBy, summarize, uncoveredOutcomes } from './orbit'

const plan = {
  id: 'plan-x', revision: 2,
  outcomes: [{ id: 'o1', title: 'one' }, { id: 'o2', title: 'two' }],
  acceptanceCriteria: [
    { id: 'a1', outcomeId: 'o1' }, { id: 'a2', outcomeId: 'o1' },
    { id: 'b1', outcomeId: 'o2' }, { id: 'b2', outcomeId: 'o2' },
  ],
}

describe('orbit summary', () => {
  test('newest plan revision wins', async () => {
    expect(pickPlan([{ id: 'p', revision: 1 }, { id: 'p', revision: 3 }, { id: 'p', revision: 2 }])?.revision).toBe(3)
    expect(pickPlan([])).toBe(null)
  })

  test('newest reconciliation for the plan wins', async () => {
    const recs = [
      { planId: 'plan-x', reconciledAt: '2026-10-01T00:00:00Z', id: 'r1' },
      { planId: 'plan-x', reconciledAt: '2026-10-04T00:00:00Z', id: 'r2' },
      { planId: 'other', reconciledAt: '2026-10-05T00:00:00Z', id: 'r3' },
    ]
    expect(pickReconciliation(recs, 'plan-x')?.id).toBe('r2')
  })

  test('percentages: achieved 1, partly 0.5; missing assessments are not verified', async () => {
    const rec = { criterionAssessments: [
      { criterionId: 'a1', status: 'achieved' },
      { criterionId: 'a2', status: 'partially-verified' },
      { criterionId: 'b1', status: 'contradicted' },
    ], reconciledAt: '2026-10-04T00:00:00Z' }
    const s = summarize(plan, rec, [{ id: 's1', planId: 'plan-x', contributesTo: ['b2'] }, { id: 'other', planId: 'nope', contributesTo: [] }])
    expect(s.outcomes[0]?.pct).toBe(75)
    expect(s.outcomes[1]?.pct).toBe(0)
    expect(s.outcomes[1]?.criteria[1]?.status).toBe('not-verified')
    expect(s.totals).toEqual({ achieved: 1, partly: 1, contradicted: 1, total: 4 })
    expect(s.slices).toEqual([{ id: 's1', contributesTo: ['b2'] }])
    expect(bandText(s)).toBe('plan-x r2 · 1/4 achieved · 1 partly · 1 contradicted')
  })

  test('no reconciliation means everything not verified', async () => {
    const s = summarize(plan, null, [])
    expect(s.reconciledAt).toBe(null)
    expect(s.totals.achieved).toBe(0)
    expect(s.outcomes.every(o => o.pct === 0)).toBe(true)
  })

  test('progress bar width and bounds', async () => {
    expect(bar(50, 10)).toBe('█████░░░░░')
    expect(bar(150, 4)).toBe('████')
    expect(bar(-5, 4)).toBe('░░░░')
  })

  test('statement and evidence are split; long text is clipped', async () => {
    expect(splitShownBy('Do X now. Shown by: a test.')).toEqual({ statement: 'Do X now.', shownBy: 'a test.' })
    expect(splitShownBy('No evidence form.')).toEqual({ statement: 'No evidence form.', shownBy: '' })
    expect(clip('abcdefghij', 6)).toBe('abcde…')
    expect(clip('short', 20)).toBe('short')
  })

  test('short label is the first sentence', async () => {
    expect(shortLabel('The App lists PR files without Contents permission. The token has three scopes.')).toBe('The App lists PR files without Contents permission')
    expect(shortLabel('P1: the two-org isolation test passes. It goes through the store.')).toBe('P1: the two-org isolation test passes')
    expect(shortLabel('No full stop here')).toBe('No full stop here')
    expect(shortLabel('x'.repeat(100), 20)).toBe('x'.repeat(19) + '…')
  })
})

describe('uncovered outcomes', () => {
  const o = (id: string, pct: number, crit: string[]) => ({ id, title: id, pct, achieved: 0, partly: 0, contradicted: 0, total: crit.length, criteria: crit.map(c => ({ id: c, status: 'not-verified', statement: '', shownBy: '' })) })
  const base = { planId: 'p', revision: 1, reconciledAt: null, totals: { achieved: 0, partly: 0, contradicted: 0, total: 0 } }
  test('flags only unfinished outcomes that no slice contributes to', () => {
    const s = { ...base, outcomes: [o('o1', 90, ['ac1-1']), o('o4', 0, ['ac4-1', 'ac4-2']), o('o5', 10, ['ac5-1', 'ac5-2']), o('o9', 100, ['ac9-1'])], slices: [{ id: 'slice-t1', contributesTo: ['ac1-1'] }, { id: 'slice-t6', contributesTo: ['ac5-2'] }] }
    expect(uncoveredOutcomes(s).map(x => x.id)).toEqual(['o4'])
  })
  test('slices sort by number, so t10 follows t9', () => {
    const plan = { id: 'p', revision: 1, outcomes: [], acceptanceCriteria: [] }
    const mk = (id: string) => ({ id, planId: 'p', contributesTo: [] })
    const s = summarize(plan, null, [mk('slice-t10-x'), mk('slice-t9-y'), mk('slice-t1-z'), mk('slice-t4-w')])
    expect(s.slices.map(sl => sl.id)).toEqual(['slice-t1-z', 'slice-t4-w', 'slice-t9-y', 'slice-t10-x'])
  })

  test('no slices means every unfinished outcome is flagged', () => {
    const s = { ...base, outcomes: [o('o1', 0, ['a']), o('o2', 100, ['b'])], slices: [] }
    expect(uncoveredOutcomes(s).map(x => x.id)).toEqual(['o1'])
  })
})

describe('mergeRecords', () => {
  test('keeps records from every branch and lets the later branch win a duplicate', () => {
    const main = [{ id: 'p', revision: 3, title: 'main' }, { id: 'q', revision: 1 }]
    const dev = [{ id: 'p', revision: 3, title: 'dev' }, { id: 'p', revision: 4 }]
    const merged = mergeRecords([main, dev])
    expect(merged.length).toBe(3)
    expect(merged.find(r => r.id === 'p' && r.revision === 3)?.title).toBe('dev')
    expect(pickPlan(merged.filter(r => r.id === 'p'))?.revision).toBe(4)
  })
  test('skips records without an id', () => {
    expect(mergeRecords([[{ revision: 1 }], [{ id: 'x' }]]).map(r => r.id)).toEqual(['x'])
  })
})

describe('initiative details', () => {
  test('uses the plan title', () => {
    expect(summarize({ ...plan, title: 'Ship the dashboard' }, null, []).title).toBe('Ship the dashboard')
  })
  test('reads the latest no-change date only inside Checks', () => {
    expect(checksDate('# Notes\n2026-12-01, abc: checked, no change.\n## Checks\n- 2026-10-12, 3a31d4e: checked, no change.\n2026-10-01, abc: checked, no change.\n2026-11-01, abc: changed.\n## Next\n2026-12-02, abc: checked, no change.')).toBe('2026-10-12')
    expect(checksDate('## Checks\nNothing checked yet.')).toBe(null)
    expect(checksDate('2026-10-12, abc: checked, no change.')).toBe(null)
  })
  test('formats deduplicated open work and the last activity', () => {
    const issue = { repo: 'a/b', number: 1, title: 'Ticket', state: 'open', updatedAt: '2026-10-11T10:00:00Z',
      prs: [{ repo: 'a/b', number: 2, title: 'PR', state: 'open', approved: true, ready: true, updatedAt: '2026-10-12T11:00:00Z' },
        { repo: 'a/b', number: 3, title: 'Closed', state: 'closed' }] }
    expect(inFlightText([{ status: 'done', issues: [issue] }, { status: 'done', issues: [issue] }])).toBe('in flight: 1 open tickets · 1 open PRs · 1 approved · 1 ready · last activity 2026-10-12T11:00:00Z')
    expect(inFlightText([{ status: 'done', issues: [{ ...issue, state: 'closed' }] }])).toBe('in flight: 0 open tickets · 0 open PRs · 0 approved · 0 ready · last activity 2026-10-12T11:00:00Z')
    expect(inFlightText([])).toBe('in flight: 0 open tickets · 0 open PRs · 0 approved · 0 ready · last activity none')
  })
  test('failed and missing lookups display offline', () => {
    expect(inFlightText([{ status: 'error', issues: [] }])).toBe('in flight (offline)')
    expect(inFlightText([undefined])).toBe('in flight (offline)')
    expect(inFlightText([{ status: 'loading', issues: [] }])).toBe('in flight: loading…')
  })
})
