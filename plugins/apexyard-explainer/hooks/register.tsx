// ApexYard explainer pane. Display only; templates only. No model, network,
// process or file calls. No file writes. All gates stay in .claude/hooks/.
import { atom, read, update } from 'claude-code'
import type { Register } from 'claude-code'

import { explain } from './explain'

const PANE = 'apexyard-explainer'
const COMMAND = 'explainer-toggle'
export const KEEP = 5
const lines = atom({ plugin: 'apexyard-explainer', key: 'lines' } as const, [])

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const result = await next(e)
    try {
      await $.command.register({ name: COMMAND, description: 'Open or close the explainer pane', immediate: true })
    } catch {}
    return result
  })

  on('command.run', { command: COMMAND }, async $ => {
    if ((await $.ui.panes()).some(p => p.id === PANE)) await $.ui.close({ id: PANE })
    else await $.ui.open({ id: PANE, title: 'Explainer', rows: KEEP + 2 })
    return {}
  })

  on('tool.call', async ($, e, next) => {
    try {
      const text = explain(e.tool, e as unknown as Record<string, unknown>)
      await update($, lines, list => [...list, { id: String(e.tool_use_id ?? ''), text }].slice(-KEEP))
    } catch {}
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text } = $.ui.resolve(e)
    const list = await read($, lines)
    if (!list.length) return <Text key="empty" dimColor>No tool calls yet.</Text>
    return (
      <Box flexDirection="column">
        {list.map((line, index) => (
          <Text key={`${index}-${line.id}`} wrap="wrap" dimColor={index < list.length - 1}>
            {line.text}
          </Text>
        ))}
      </Box>
    )
  })
}
