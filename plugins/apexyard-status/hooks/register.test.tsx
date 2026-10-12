import type { On } from 'claude-code'
import { describe, expect, test } from 'claude-code/testing'

import type { Band } from '../types'

// The test's hooks sit beneath the plugin and stand for the engine. This
// state.get hook answers the plugin's read of its own band value. On this
// build the kit hands the plugin the `value` field of the hook's answer, so
// the answer carries the whole StateRead in `value`.
function holdBand(on: On, band: Band | null) {
  on(
    'state.get',
    { plugin: 'apexyard-status', key: 'band' },
    async () => ({ value: { value: band ?? undefined, version: 1 }, version: 1 }) as never,
  )
}

const SURFACES = ['terminal', 'desktop'] as const

const BAND = {
  plugin: 'apexyard-status',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 10,
    bodyColumns: 120,
    scroll: { offset: 0, bodyRows: 10 },
    view: {},
  },
  viewport: { columns: 125, rows: 40 },
} as const

describe('status band', () => {
  test('draws the ticket, the merge queue, the reviewer lock and the build count', async ($, on) => {
    holdBand(on, {
      ticket: 'apexyard#1541 Optional status band',
      waiting: ['me2resh/apexyard#12'],
      reReview: ['me2resh/apexyard#14'],
      offline: false,
      reviewLock: 'me2resh/apexyard#13 (rex)',
      builds: 2,
    })
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: 'apexyard#1541 Optional status band' })).toBeDefined()
      expect(
        await ui.find({ type: 'Text', text: '1 waiting for your /approve-merge: me2resh/apexyard#12' }),
      ).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'review lock: me2resh/apexyard#13 (rex)' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '2 builds running' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '1 needs re-review: me2resh/apexyard#14' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '(offline)' })).toBe(undefined)
      await ui.unmount()
    }
  })

  test('shows the empty states and hides the lock and the build count', async ($, on) => {
    holdBand(on, { ticket: null, waiting: [], reReview: [], offline: false, reviewLock: null, builds: null })
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: 'no active ticket' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'nothing waiting for /approve-merge' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'review lock' })).toBe(undefined)
      expect(await ui.find({ type: 'Text', text: 'running' })).toBe(undefined)
      expect(await ui.find({ type: 'Text', text: 're-review' })).toBe(undefined)
      await ui.unmount()
    }
  })

  test('marks the count offline when the open-PR check failed', async ($, on) => {
    holdBand(on, { ticket: null, waiting: ['a/b#1'], reReview: [], offline: true, reviewLock: null, builds: null })
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: '1 waiting for your /approve-merge (offline): a/b#1' })).toBeDefined()
      await ui.unmount()
    }
  })

  test('yields the band outside an ops fork', async ($, on) => {
    holdBand(on, null)
    // Stands for the engine's own band, which the plugin yields to.
    on('ui.render', { component: 'AbovePrompt' }, async ($$, e) => {
      const { Text } = $$.ui.resolve(e)
      return <Text>engine band</Text>
    })
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, surface })
      expect(await ui.find({ type: 'Text', text: 'engine band' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'ApexYard' })).toBe(undefined)
      await ui.unmount()
    }
  })
})

// Pane fixtures use the same state envelope as the band fixtures above.
describe('ORBIT initiatives pane', () => {
  test('renders the title, initiative name, in-flight work and check date on both surfaces', async ($, on) => {
    on('state.get', { plugin: 'apexyard-status', key: 'orbit' }, async () => ({ value: { value: {
      activeRepo: 'a/b', updatedAt: 0, plans: [{ key: 'a/b#plan-x', repo: 'a/b', summary: {
        title: 'Ship the dashboard', planId: 'plan-x', revision: 2, reconciledAt: '2026-10-01', checkedAt: '2026-10-12',
        outcomes: [], slices: [{ id: 'slice-t1', contributesTo: [] }],
        totals: { achieved: 0, partly: 0, contradicted: 0, total: 0 },
      } }],
    }, version: 1 }, version: 1 }) as never)
    on('state.get', { plugin: 'apexyard-status', key: 'expanded' }, async () => ({ value: { value: {}, version: 1 }, version: 1 }) as never)
    on('state.get', { plugin: 'apexyard-status', key: 'sliceLinks' }, async () => ({ value: { value: {
      'a/b/slice-t1': { status: 'error', issues: [] },
    }, version: 1 }, version: 1 }) as never)
    for (const surface of SURFACES) {
      const ui = await $.ui.mount({ ...BAND, component: 'Pane', requestId: 'orbit-progress', surface })
      expect(await ui.find({ type: 'Text', text: 'ORBIT initiatives · 1 in 1 repos' })).toBeDefined()
      expect(await ui.find({ type: 'Button', text: 'Ship the dashboard' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'in flight (offline)' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'plan-x r2 · reconciled 2026-10-01 · checked 2026-10-12' })).toBeDefined()
      await ui.unmount()
    }
  })
})

test('collapsed initiative uses its title and hides the plan ID', async ($, on) => {
  on('state.get', { plugin: 'apexyard-status', key: 'orbit' }, async () => ({ value: { value: {
    activeRepo: null, updatedAt: 0, plans: [{ key: 'a/b#internal-plan-id', repo: 'a/b', summary: {
      title: 'Customer onboarding', planId: 'internal-plan-id', revision: 1, reconciledAt: null,
      outcomes: [], slices: [], totals: { achieved: 0, partly: 0, contradicted: 0, total: 0 },
    } }],
  }, version: 1 }, version: 1 }) as never)
  on('state.get', { plugin: 'apexyard-status', key: 'expanded' }, async () => ({ value: { value: {}, version: 1 }, version: 1 }) as never)
  on('state.get', { plugin: 'apexyard-status', key: 'sliceLinks' }, async () => ({ value: { value: {}, version: 1 }, version: 1 }) as never)
  for (const surface of SURFACES) {
    const ui = await $.ui.mount({ ...BAND, component: 'Pane', requestId: 'orbit-progress', surface })
    expect(await ui.find({ type: 'Button', text: 'Customer onboarding' })).toBeDefined()
    expect(await ui.find({ type: 'Button', text: 'internal-plan-id' })).toBe(undefined)
    expect(await ui.find({ type: 'Text', text: 'internal-plan-id' })).toBe(undefined)
    expect(await ui.find({ type: 'Text', text: 'in flight: 0 open tickets · 0 open PRs' })).toBeDefined()
    await ui.unmount()
  }
})
