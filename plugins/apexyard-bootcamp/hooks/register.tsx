// Display only. No model, network, process, file calls or hook replacement.
import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'
import { checkpointKey, contentError, initial, loadLessons, navigate, normalize, tick } from './bootcamp'
import { content } from './content.generated'

const PANE = 'apexyard-bootcamp'
export const lessons = loadLessons(content)
export const progress = atom({ plugin: 'apexyard-bootcamp', key: 'progress' } as const, initial())
const commands = {
  bootcamp: 'Open or close the Bootcamp pane',
  'bootcamp-next': 'Show the next bootcamp step',
  'bootcamp-back': 'Show the previous bootcamp step',
  'bootcamp-goto': 'Show module and step: /bootcamp-goto <module> <step>',
  'bootcamp-reset': 'Reset bootcamp progress and checkpoints',
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    for (const [name, description] of Object.entries(commands)) {
      try { await $.command.register({ name, description, immediate: true }) } catch {}
    }
    return result
  })
  for (const command of Object.keys(commands)) {
    on('command.run', { command }, async ($, e) => {
      if (command === 'bootcamp') {
        if ((await $.ui.panes()).some(p => p.id === PANE)) await $.ui.close({ id: PANE })
        else await $.ui.open({ id: PANE, title: 'Bootcamp', rows: 18 })
      } else await update($, progress, p => navigate(p, lessons, command, e.args))
      return {}
    })
  }
  on('tool.call', async ($, e, next) => {
    const result = await next(e)
    if (result.deny === undefined) {
      const event = e.tool === 'Skill' ? { tool: e.tool, skill: e.skill }
        : e.tool === 'Bash' ? { tool: e.tool, command: e.command } : { tool: e.tool }
      try { await update($, progress, p => tick(p, lessons, event)) } catch {}
    }
    return result
  })
  on('skill.prompt', async ($, e, next) => {
    const result = await next(e)
    try { await update($, progress, p => tick(p, lessons, { tool: 'Skill', skill: e.skill })) } catch {}
    return result
  })
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const p = normalize(await read($, progress), lessons)
    const lesson = lessons[p.module]
    const module = lesson?.module
    const step = module?.steps[p.step]
    if (!module || !step) return <Text color="red" wrap="wrap">{contentError(lesson)}</Text>
    const done = p.ticked[checkpointKey(p)] === true
    return (
      <Box flexDirection="column">
        <Text bold wrap="wrap">{`Bootcamp · Module ${p.module + 1}: ${module.title} · step ${p.step + 1}/${module.steps.length}`}</Text>
        <Text wrap="wrap">{module.steps.map((s, i) => p.ticked[`${p.module}:${i}`] ? '[x]' : i === p.step ? '[>]' : '[ ]').join(' ')}</Text>
        <Text bold wrap="wrap">{step.title}</Text>
        <Text wrap="wrap">{step.body}</Text>
        {step.try ? <Box flexDirection="column" borderStyle="round"><Text bold>Try it</Text><Text wrap="wrap">{step.try}</Text></Box> : null}
        {step.check ? <Text wrap="wrap" color={done ? 'green' : undefined}>{done ? `[x] ${step.done ?? 'Matching tool call observed.'}` : '[ ] Waiting for you to run it'}</Text> : null}
        {step.note ? <Text dimColor wrap="wrap">{step.note}</Text> : null}
        <Text dimColor wrap="wrap">/bootcamp-next · /bootcamp-back</Text>
      </Box>
    )
  })
}
