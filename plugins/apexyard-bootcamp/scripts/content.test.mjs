import { test } from 'node:test'
import { strict as assert } from 'node:assert'
import { readFileSync, readdirSync } from 'node:fs'
// --check prevents the build module from writing files during a test.
process.argv.push('--check')
const { generatedContent } = await import('./build-content.mjs')
test('bundled Markdown is current', () => {
  assert.equal(readFileSync(new URL('../hooks/content.generated.ts', import.meta.url), 'utf8'), generatedContent())
})
test('all content files use the documented module naming convention', () => {
  const files = readdirSync(new URL('../content/', import.meta.url))
  assert.equal(files.length, 9)
  files.sort().forEach((file, i) => assert.match(file, new RegExp(`^${String(i + 1).padStart(2, '0')}-[a-z0-9-]+\\.md$`)))
})
