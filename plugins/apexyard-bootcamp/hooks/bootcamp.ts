import type { Check, Lesson, Module, Progress, Step } from '../types/index.d.ts'

export function parseModule(text: string): Module {
  const lines = text.replace(/\r\n/g, '\n').trim().split('\n')
  const title = lines.shift()?.match(/^# (\S.*)$/)?.[1]
  if (!title) throw new Error('Expected # Module title on the first line.')
  const steps: Step[] = []
  let step: Step | undefined
  let metadata = false
  const finish = () => {
    if (step && !step.body.trim()) throw new Error(`Step "${step.title}" needs body text.`)
    if (step) step.body = step.body.trim()
  }
  for (const line of lines) {
    const heading = line.match(/^## (\S.*)$/)
    if (heading?.[1]) {
      finish()
      step = { title: heading[1], body: '' }
      steps.push(step)
      metadata = false
      continue
    }
    if (!line.trim()) { if (step && !metadata) step.body += '\n'; continue }
    if (!step) throw new Error('Expected ## Step title before body text.')
    if (/^#/.test(line)) throw new Error('Only module and step headings are allowed.')
    const field = line.match(/^(Try|Check|Done|Note):\s*(.*)$/)
    if (field) {
      metadata = true
      const value = field[2]?.trim() ?? ''
      if (!value) throw new Error(`${field[1]} needs a value.`)
      if (field[1] === 'Check') {
        if (step.check) throw new Error('Duplicate Check field.')
        const check = value.match(/^(skill|bash) (.+)$/)
        if (!check?.[2]) throw new Error('Check must use skill <name> or bash <regex>.')
        const kind = check[1] === 'skill' ? 'skill' : 'bash'
        if (kind === 'bash') new RegExp(check[2], 'i')
        else if (!/^[\w-]+(?::[\w-]+)*$/.test(check[2])) throw new Error('Invalid skill name.')
        step.check = { kind, value: check[2] }
      } else {
        const key = field[1] === 'Try' ? 'try' : field[1] === 'Done' ? 'done' : 'note'
        if (step[key]) throw new Error(`Duplicate ${field[1]} field.`)
        step[key] = value
      }
    } else {
      if (metadata) throw new Error('Body text must precede metadata.')
      step.body += `${line}\n`
    }
  }
  finish()
  if (!steps.length) throw new Error('Module needs at least one step.')
  return { title, steps }
}

export function loadLessons(files: ReadonlyArray<{ file: string; text: string }>): Lesson[] {
  return files.map(({ file, text }) => {
    try { return { file, module: parseModule(text) } }
    catch (error) { return { file, error: error instanceof Error ? error.message : 'Invalid Markdown.' } }
  })
}

export function matches(check: Check | undefined, event: Record<string, unknown>): boolean {
  if (!check) return false
  if (check.kind === 'skill') {
    const skill = event.skill
    return event.tool === 'Skill' && typeof skill === 'string'
      && skill.split(':').pop() === check.value.split(':').pop()
  }
  if (event.tool !== 'Bash' || typeof event.command !== 'string') return false
  if (event.command.length > 32000) return false
  try { return new RegExp(check.value, 'i').test(event.command) } catch { return false }
}

export const initial = (): Progress => ({ module: 0, step: 0, ticked: {} })
export const checkpointKey = (p: Progress): string => `${p.module}:${p.step}`

export function normalize(value: unknown, lessons: Lesson[]): Progress {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return initial()
  const p = value as Record<string, unknown>
  if (typeof p.module !== 'number' || !Number.isInteger(p.module)
    || typeof p.step !== 'number' || !Number.isInteger(p.step)
    || !p.ticked || typeof p.ticked !== 'object' || Array.isArray(p.ticked)
    || ![Object.prototype, null].includes(Object.getPrototypeOf(p.ticked))) return initial()
  const module = Math.max(0, Math.min(Math.max(0, lessons.length - 1), p.module))
  const last = (lessons[module]?.module?.steps.length ?? 1) - 1
  const step = Math.max(0, Math.min(last, p.step))
  const ticked = Object.fromEntries(Object.entries(p.ticked).filter(([, v]) => v === true))
  return { module, step, ticked }
}

export function navigate(p: Progress, lessons: Lesson[], command: string, args = ''): Progress {
  if (command === 'bootcamp-reset') return initial()
  const current = normalize(p, lessons)
  let { module, step } = current
  if (command === 'bootcamp-goto') {
    if (!/^\s*\d+\s+\d+\s*$/.test(args)) return current
    const numbers = args.trim().split(/\s+/).map(Number)
    module = (numbers[0] ?? 1) - 1
    step = (numbers[1] ?? 1) - 1
  } else if (command === 'bootcamp-next') {
    if (step + 1 < (lessons[module]?.module?.steps.length ?? 1)) step++
    else if (module + 1 < lessons.length) { module++; step = 0 }
  } else if (command === 'bootcamp-back') {
    if (step > 0) step--
    else if (module > 0) { module--; step = (lessons[module]?.module?.steps.length ?? 1) - 1 }
  }
  return normalize({ ...current, module, step }, lessons)
}

export function tick(p: Progress, lessons: Lesson[], event: Record<string, unknown>): Progress {
  const current = normalize(p, lessons)
  const check = lessons[current.module]?.module?.steps[current.step]?.check
  return matches(check, event)
    ? { ...current, ticked: { ...current.ticked, [checkpointKey(current)]: true } } : current
}

export function contentError(lesson: Lesson | undefined): string {
  return `Bootcamp content error: ${lesson?.file ?? 'unknown module'}: ${lesson?.error ?? 'No steps available.'}`
}
