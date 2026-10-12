import { describe, expect, test } from 'claude-code/testing'
import { contentError, initial, loadLessons, matches, navigate, normalize, parseModule, tick } from './bootcamp'
import { content } from './content.generated'

const good = '# Sample\n\n## First\nUse Corner Shop.\nTry: /setup\nCheck: skill setup\nDone: Setup call observed.\nNote: Explain the setup.\n\n## Second\nInspect the result.'
const lessons = loadLessons([{ file: '01-sample.md', text: good }, { file: '02-last.md', text: '# Last\n## End\nRead the results.' }])

describe('Markdown parser', () => {
  test('parses titles, body and optional fields', async () => {
    expect(parseModule(good)).toEqual({ title: 'Sample', steps: [
      { title: 'First', body: 'Use Corner Shop.', try: '/setup', check: { kind: 'skill', value: 'setup' }, done: 'Setup call observed.', note: 'Explain the setup.' },
      { title: 'Second', body: 'Inspect the result.' },
    ] })
  })
  test('keeps each malformed file as a clear error', async () => {
    for (const text of ['## Missing module', '# Empty', '# A\nbody', '# A\n## B', '# A\n## B\nBody.\nCheck: bash [', '# A\n## B\nBody.\nTry:', '# A\n## B\nBody.\nCheck: other x', '# A\n## B\nBody.\nTry: x\nTry: y', '# A\n## B\nBody.\nNote: x\nLate body']) {
      const result = loadLessons([{ file: 'bad.md', text }])[0]
      expect(result?.module).toBe(undefined)
      expect(Boolean(result?.error)).toBe(true)
      expect(contentError(result).startsWith('Bootcamp content error: bad.md: ')).toBe(true)
    }
  })
  test('loads nine ASCII modules with three to six steps', async () => {
    const loaded = loadLessons(content)
    expect(loaded.length).toBe(9)
    for (const lesson of loaded) {
      expect(lesson.error).toBe(undefined)
      const count = lesson.module?.steps.length ?? 0
      expect(count >= 3 && count <= 6).toBe(true)
    }
    for (const file of content) {
      expect(/^[\x09\x0a\x0d\x20-\x7e]*$/.test(file.text)).toBe(true)
      for (const line of file.text.split('\n').filter(l => l && !/^(#|Try:|Check:)/.test(l))) {
        for (const sentence of line.replace(/^(Done|Note): /, '').split(/[.!?](?:\s|$)/).filter(Boolean)) {
          expect(sentence.trim().split(/\s+/).length <= 20).toBe(true)
        }
      }
    }
  })
})

describe('checkpoints', () => {
  test('matches skill names with or without a plugin prefix', async () => {
    const check = { kind: 'skill', value: 'setup' } as const
    expect(matches(check, { tool: 'Skill', skill: 'setup' })).toBe(true)
    expect(matches(check, { tool: 'Skill', skill: 'apexyard:setup' })).toBe(true)
    expect(matches({ kind: 'skill', value: 'apexyard:setup' }, { tool: 'Skill', skill: 'setup' })).toBe(true)
    for (const event of [{ tool: 'Skill', skill: 'setup-more' }, { tool: 'Skill', skill: 'onboard' }, { tool: 'Bash', skill: 'setup' }, { tool: 'Skill' }]) expect(matches(check, event)).toBe(false)
  })
  test('matches Bash regex without ticking another tool', async () => {
    const check = { kind: 'bash', value: '\\bgh\\s+pr\\s+create\\b' } as const
    expect(matches(check, { tool: 'Bash', command: 'GH PR CREATE --draft' })).toBe(true)
    for (const event of [{ tool: 'Bash', command: 'gh pr view' }, { tool: 'Read', command: 'gh pr create' }, { tool: 'Bash' }]) expect(matches(check, event)).toBe(false)
    expect(matches({ kind: 'bash', value: '[' }, { tool: 'Bash', command: 'x' })).toBe(false)
    expect(matches(undefined, { tool: 'Skill', skill: 'setup' })).toBe(false)
  })
  test('the bundled PR checkpoint matches the real command', async () => {
    const course = loadLessons(content)
    const p = navigate(initial(), course, 'bootcamp-goto', '5 5')
    expect(tick(p, course, { tool: 'Bash', command: 'gh pr create --draft' }).ticked).toEqual({ '4:4': true })
    for (const command of ['gh pr view', 'gh pr create --help', 'gh pr create --draft --help', 'rg "gh pr create" .', 'echo gh pr create', 'gh pr create ' + 'x'.repeat(32000)]) {
      expect(tick(p, course, { tool: 'Bash', command }).ticked).toEqual({})
    }
    // Real PR commands with an inline body reach about 7,000 characters and must still tick.
    const longBody = 'gh pr create --draft --title "feat: x" --body "' + 'y'.repeat(7000) + '"'
    expect(tick(p, course, { tool: 'Bash', command: longBody }).ticked).toEqual({ '4:4': true })
    expect(tick(p, course, { tool: 'Bash', command: 'git status && gh pr create --draft' }).ticked).toEqual({ '4:4': true })
  })
  test('ticks only the current step and preserves earlier ticks', async () => {
    const p = tick(initial(), lessons, { tool: 'Skill', skill: 'apexyard:setup' })
    expect(p.ticked).toEqual({ '0:0': true })
    expect(tick(navigate(p, lessons, 'bootcamp-next'), lessons, { tool: 'Skill', skill: 'setup' }).ticked).toEqual(p.ticked)
    expect(tick(initial(), lessons, { tool: 'Skill', skill: 'onboard' })).toEqual(initial())
  })
})

describe('navigation and serialized progress', () => {
  test('next and back cross modules and stop at the ends', async () => {
    let p = initial()
    expect(navigate(p, lessons, 'bootcamp-back')).toEqual(p)
    p = navigate(p, lessons, 'bootcamp-next')
    expect([p.module, p.step]).toEqual([0, 1])
    p = navigate(p, lessons, 'bootcamp-next')
    expect([p.module, p.step]).toEqual([1, 0])
    expect(navigate(p, lessons, 'bootcamp-next')).toEqual(p)
    expect(navigate(p, lessons, 'bootcamp-back').step).toBe(1)
  })
  test('goto uses one-based bounds and reset clears all ticks', async () => {
    const p = { module: 0, step: 0, ticked: { '0:0': true } }
    expect(navigate(p, lessons, 'bootcamp-goto', '99 99')).toEqual({ module: 1, step: 0, ticked: p.ticked })
    expect(navigate(p, lessons, 'bootcamp-goto', '0 0')).toEqual(p)
    expect(navigate(p, lessons, 'bootcamp-goto', '1 99').step).toBe(1)
    for (const args of ['x y', '1', '-1 1', '1 1 extra', '1.5 2']) expect(navigate(p, lessons, 'bootcamp-goto', args)).toEqual(p)
    expect(navigate(p, lessons, 'bootcamp-reset')).toEqual(initial())
  })
  test('null and malformed store values restore fresh progress', async () => {
    for (const value of [null, undefined, 'bad', [], {}, { module: 1, step: 0, ticked: [] }, { module: 1, step: 0, ticked: 'bad' }]) {
      expect(normalize(value, lessons)).toEqual(initial())
    }
  })
  test('resumes module, step and ticks from a store snapshot', async () => {
    const saved = navigate(tick(initial(), lessons, { tool: 'Skill', skill: 'setup' }), lessons, 'bootcamp-next')
    const restored = JSON.parse(JSON.stringify(saved))
    expect(navigate(restored, lessons, 'bootcamp-back')).toEqual({ module: 0, step: 0, ticked: { '0:0': true } })
  })
})
