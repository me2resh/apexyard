import { describe, expect, test } from 'claude-code/testing'
const PANE = {
  component: 'Pane', requestId: 'apexyard-bootcamp', plugin: 'apexyard-bootcamp',
  viewport: { columns: 80, rows: 24 },
  props: { title: 'Bootcamp', isFocused: false, bodyColumns: 60, placement: 'inline', scroll: { offset: 0, bodyRows: 18 }, view: {} },
} as const
const command = (name: string, args = '') => ({ command: name, args }) as never

describe('bootcamp pane', () => {
  test('toggle opens and closes', async ($, on) => {
    const calls: unknown[] = []
    let open = false
    on('ui.panes', () => ({ value: open ? [{ id: 'apexyard-bootcamp', title: 'Bootcamp', isShown: true, isFocused: false, isPlaced: true }] : [] }))
    on('ui.open', ($$, e) => { calls.push(e); open = true; return { value: { isPlaced: true } } })
    on('ui.close', ($$, e) => { calls.push(e); open = false; return { value: undefined } })
    await $.command.run(command('bootcamp'))
    await $.command.run(command('bootcamp'))
    expect(calls).toEqual([{ id: 'apexyard-bootcamp', title: 'Bootcamp', rows: 18 }, { id: 'apexyard-bootcamp', origin: { kind: 'plugin' } }])
  })
  test('renders layout and a real checkpoint on narrow and wide panes', async ($, on) => {
    on('tool.call', () => ({ result: 'ok' }))
    await $.command.run(command('bootcamp-goto', '1 2'))
    for (const placement of ['inline', 'dock'] as const) {
      const ui = await $.ui.mount({ ...PANE, surface: 'terminal', props: { ...PANE.props, placement, bodyColumns: placement === 'inline' ? 40 : 70 } })
      expect(await ui.find({ type: 'Text', text: 'Bootcamp · Module 1: Setup · step 2/3' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: 'Try it' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '/setup' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '[ ] Waiting for you to run it' })).toBeDefined()
      expect(await ui.find({ type: 'Text', text: '/bootcamp-next · /bootcamp-back' })).toBeDefined()
      await ui.unmount()
    }
    await $.tool.call({ tool: 'Skill', skill: 'apexyard:setup' })
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '[x] You configured ApexYard.' })).toBeDefined()
    await ui.unmount()
  })
  test('typed skill prompts tick after passing through unchanged', async ($, on) => {
    on('skill.prompt', async () => {
      const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
      expect(await ui.find({ type: 'Text', text: '[ ] Waiting for you to run it' })).toBeDefined()
      await ui.unmount()
      return { text: 'Original skill prompt' }
    })
    await $.command.run(command('bootcamp-goto', '1 2'))
    expect(await $.skill.prompt({ skill: 'apexyard:setup', text: 'Input' })).toEqual({ text: 'Original skill prompt' })
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '[x] You configured ApexYard.' })).toBeDefined()
    await ui.unmount()
  })
  test('denied Skill calls do not tick and pass through the denial', async ($, on) => {
    on('tool.call', () => ({ deny: 'Blocked by gate' }))
    await $.command.run(command('bootcamp-goto', '1 2'))
    expect(await $.tool.call({ tool: 'Skill', skill: 'setup' })).toEqual({ deny: 'Blocked by gate' })
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '[ ] Waiting for you to run it' })).toBeDefined()
    await ui.unmount()
  })
  test('a null host store restores fresh progress', async ($, on) => {
    on('state.get', { plugin: 'apexyard-bootcamp', key: 'progress' }, async () => ({ value: { value: null, version: 1 }, version: 1 }) as never)
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: 'Bootcamp · Module 1: Setup · step 1/3' })).toBeDefined()
    await ui.unmount()
  })
  test('commands preserve store state while pane closes and remounts', async ($, on) => {
    on('tool.call', () => ({ result: 'ok' }))
    await $.command.run(command('bootcamp-goto', '1 2'))
    await $.tool.call({ tool: 'Skill', skill: 'setup' })
    await $.command.run(command('bootcamp-next'))
    const next = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await next.find({ type: 'Text', text: 'Bootcamp · Module 1: Setup · step 3/3' })).toBeDefined()
    await next.unmount()
    await $.command.run(command('bootcamp-back'))
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: '[x] You configured ApexYard.' })).toBeDefined()
    await ui.unmount()
    await $.command.run(command('bootcamp-reset'))
    await $.command.run(command('bootcamp-next'))
    const reset = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await reset.find({ type: 'Text', text: '[ ] Waiting for you to run it' })).toBeDefined()
    await reset.unmount()
  })
  test('resumes a host store snapshot after runtime initialization', async ($, on) => {
    const snapshot = JSON.parse('{"module":4,"step":5,"ticked":{"4:5":true,"0:1":true}}')
    on('state.get', { plugin: 'apexyard-bootcamp', key: 'progress' }, async () => ({ value: { value: snapshot, version: 1 }, version: 1 }) as never)
    const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
    expect(await ui.find({ type: 'Text', text: 'Bootcamp · Module 5: A vibe-coded request · step 6/6' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: '[x] You asked Rex for a review.' })).toBeDefined()
    await ui.unmount()
  })
})
