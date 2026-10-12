import { describe, expect, test } from 'claude-code/testing'

const PANE = {
  component: 'Pane', requestId: 'apexyard-explainer', plugin: 'apexyard-explainer',
  viewport: { columns: 80, rows: 24 },
  props: {
    title: 'Explainer', isFocused: false, bodyColumns: 60, placement: 'inline',
    scroll: { offset: 0, bodyRows: 10 }, view: {},
  },
} as const

describe('explainer pane', () => {
  test('draws tool calls on terminal and desktop at both widths', async ($, on) => {
    on('tool.call', () => ({ result: 'ok' }))
    await $.tool.call({ tool: 'Read', file_path: '/a/app.ts' })
    await $.tool.call({ tool: 'Bash', command: 'npm test' })
    for (const surface of ['terminal', 'desktop'] as const) {
      for (const placement of ['inline', 'dock'] as const) {
        const ui = await $.ui.mount({ ...PANE, surface,
          viewport: { columns: placement === 'inline' ? 60 : 200, rows: 20 },
          props: { ...PANE.props, bodyColumns: placement === 'inline' ? 50 : 60, placement },
        })
        expect(await ui.find({ type: 'Text', text: 'Reads the file app.ts to learn the code.' })).toBeDefined()
        expect(await ui.find({ type: 'Text', text: 'Runs the tests to check the change.' })).toBeDefined()
        await ui.unmount()
      }
    }
  })
  test('seven calls keep only the last five lines while closed', async ($, on) => {
    on('tool.call', () => ({ result: 'ok' }))
    for (let i = 0; i < 7; i++) await $.tool.call({ tool: 'Read', file_path: `/a/file${i}.ts` })
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    for (let i = 0; i < 7; i++) {
      const found = await ui.find({ type: 'Text', text: `Reads the file file${i}.ts to learn the code.` })
      if (i < 2) expect(found).toBe(undefined)
      else expect(found).toBeDefined()
    }
    await ui.unmount()
  })
  test('an empty pane shows its empty state', async $ => {
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: 'No tool calls yet.' })).toBeDefined()
    await ui.unmount()
  })
  test('the toggle opens then closes the pane', async ($, on) => {
    const calls: unknown[] = []
    let open = false
    on('ui.panes', () => ({ value: open ? [{ id: 'apexyard-explainer', title: 'Explainer', isShown: true, isFocused: false, isPlaced: true }] : [] }))
    on('ui.open', ($$, e) => { calls.push(e); open = true; return { value: { isPlaced: true } } })
    on('ui.close', ($$, e) => { calls.push(e); open = false; return { value: undefined } })
    // The kit stamps origin and presentation; the test names the command only.
    const toggle = { command: 'explainer-toggle', args: '' } as never
    await $.command.run(toggle)
    await $.command.run(toggle)
    expect(calls).toEqual([
      { id: 'apexyard-explainer', title: 'Explainer', rows: 7 },
      { id: 'apexyard-explainer', origin: { kind: 'plugin' } },
    ])
  })
})
