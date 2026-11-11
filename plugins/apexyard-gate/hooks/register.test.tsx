import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import type { GateView } from '../types'
import { APPROVE_LABEL, approvalQuestion } from './approve'

const SHA = 'abcdef1234567890abcdef1234567890abcdef12'
const ROOT = '/ops'
const SURFACES = ['terminal', 'desktop'] as const

const PANE = {
  plugin: 'apexyard-gate',
  component: 'Pane',
  requestId: 'gate-approvals',
  props: {
    title: 'ApexYard approvals',
    isFocused: true,
    bodyColumns: 120,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
  viewport: { columns: 125, rows: 40 },
} as const

const VIEW: GateView = {
  inFork: true,
  busy: false,
  updatedAt: 0,
  rows: [{ repo: 'me2resh/apexyard', number: 1683, title: 'A change', head: SHA, rexSha: SHA, ci: 'pass', open: true, note: null }],
}

// The test's hooks sit beneath the plugin and stand for the engine.
// They count each question and each file write the plugin asks for.
async function engine(on: On, view: GateView, answer: string | null) {
  const seen = { asks: [] as string[], writes: 0, merges: 0 }
  // The kit keeps $.state. Until the plugin writes, answer with the seed.
  on('state.get', { plugin: 'apexyard-gate', key: 'view' }, async (_$, e, next) => {
    const r = (await next(e)) as { value?: { version?: number }; version?: number }
    const written = (r.value?.version ?? r.version ?? 0) > 0
    return (written ? r : { value: { value: view, version: 0 }, version: 0 }) as never
  })
  on('session.id', async () => ({ value: 's1' }) as never)
  on('session.cwd', async () => ({ value: ROOT }) as never)
  on('env.get', async () => ({ value: undefined }) as never)
  on('fs.exists', async (_$, e) => ({ value: String((e as { path?: string }).path ?? '').endsWith('/.apexyard-fork') }) as never)
  on('fs.read', async () => ({ value: `sha=${SHA}\n` }) as never)
  on('fs.write', async () => { seen.writes++; return { value: {} } as never })
  on('clock.sleep', async () => ({ value: undefined }) as never)
  on('ui.toast', async () => ({ value: undefined }) as never)
  on('process.run', async (_$, e) => {
    const argv = (e as { argv: string[] }).argv
    if (argv.includes('merge')) seen.merges++
    return { value: { exitCode: 0, stdout: JSON.stringify({ state: 'OPEN', headRefOid: SHA, title: 'A change', statusCheckRollup: [] }), stderr: '' } } as never
  })
  on('tool.call', { tool: 'AskUserQuestion' }, async (_$, e) => {
    const q = (e as { questions: { question: string }[] }).questions[0]!.question
    seen.asks.push(q)
    if (answer === null) return { deny: 'dismissed' }
    return { result: { questions: (e as { questions: unknown }).questions, answers: { [q]: answer } } } as never
  })
  return seen
}

test('the pane shows repo, PR, head SHA, CI state and the Rex verdict', async ($, on) => {
  await engine(on, VIEW, APPROVE_LABEL)
  for (const surface of SURFACES) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /me2resh\/apexyard#1683/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: new RegExp(`head ${SHA}`) })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /CI: no checks|CI: pass/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Rex: approved at abcdef1/ })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: 'Approve' })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: 'Not yet' })).toBeDefined()
    await ui.unmount()
  }
})

test('without a key press the pane asks nothing and writes nothing', async ($, on) => {
  const seen = await engine(on, VIEW, APPROVE_LABEL)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  await ui.unmount()
  expect(seen.asks.length).toBe(0)
  expect(seen.writes).toBe(0)
})

test('Approve asks the exact AgDR-0234 question once and never writes or merges', async ($, on) => {
  const seen = await engine(on, VIEW, APPROVE_LABEL)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const approve = await ui.find({ type: 'Button', text: 'Approve' })
  await ui.press({ key: approve!.key! })
  expect(seen.asks).toEqual([approvalQuestion('me2resh/apexyard', 1683, SHA)])
  expect(seen.writes).toBe(0)
  expect(seen.merges).toBe(0)
  // The record came from the stand-in hook, read back, not written by the plugin.
  expect(await ui.find({ type: 'Text', text: /menu hook recorded your approval for abcdef1/ })).toBeDefined()
  await ui.unmount()
})

test('a dismissed menu records nothing', async ($, on) => {
  const seen = await engine(on, VIEW, null)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const approve = await ui.find({ type: 'Button', text: 'Approve' })
  await ui.press({ key: approve!.key! })
  expect(seen.asks.length).toBe(1)
  expect(seen.writes).toBe(0)
  expect(await ui.find({ type: 'Text', text: /Nothing was recorded/ })).toBeDefined()
  await ui.unmount()
})

test('Not yet in the pane asks nothing', async ($, on) => {
  const seen = await engine(on, VIEW, APPROVE_LABEL)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const notYet = await ui.find({ type: 'Button', text: 'Not yet' })
  await ui.press({ key: notYet!.key! })
  expect(seen.asks.length).toBe(0)
  expect(seen.writes).toBe(0)
  await ui.unmount()
})

test('a row whose head moved past the Rex review offers no Approve', async ($, on) => {
  const moved = { ...VIEW, rows: [{ ...VIEW.rows[0]!, rexSha: '0123456' }] }
  await engine(on, moved, APPROVE_LABEL)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Button', text: 'Approve' })).toBe(undefined)
  expect(await ui.find({ type: 'Text', text: /re-review/ })).toBeDefined()
  await ui.unmount()
})
