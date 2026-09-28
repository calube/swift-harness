// Reads how the build and ship skills pick a preset, and how the bootstrap skill stamps a profile.
// Run: node tests/preset_profile_skills_test.mjs
// Regressions caught: a skill that ignores the repository's `[harness] profile` when no --preset is
// given, one that lets the profile override an explicit --preset, one that silently swaps an
// unknown profile for another preset, and a bootstrap skill that never offers --profile.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const skill = name => readFileSync(join(root, 'skills', name, 'SKILL.md'), 'utf8')

// The Value cell of a skill's Names table row for `name`.
function nameRow(text, name) {
  const row = text.split('\n').find(line => line.startsWith(`| \`${name}\` |`))
  assert.ok(row, `no ${name} row in the Names table`)
  return row.split('|')[2].trim()
}

// The sources a `<preset>` row consults, in the order it reads them.
function presetSources(row) {
  const sources = [
    ['flag', /`--preset <name>`/],
    ['profile', /`profile` key of `\[harness\]`/],
    ['default', /`default`/],
  ]
  return sources
    .map(([source, pattern]) => [source, row.search(pattern)])
    .filter(([, at]) => at >= 0)
    .sort((a, b) => a[1] - b[1])
    .map(([source]) => source)
}

const tests = {
  'with no --preset the build and ship skills use the [harness] profile, then default, and --preset overrides both — catches a profile silently ignored'() {
    for (const name of ['build', 'ship']) {
      const row = nameRow(skill(name), '<preset>')
      assert.deepEqual(presetSources(row), ['flag', 'profile', 'default'], `${name}: ${row}`)
      assert.ok(/\.swiftgate\.toml/.test(row), `${name}: the profile is not read from .swiftgate.toml`)
    }
  },

  'the resolver reads each order it is given — catches a check that passes any row'() {
    assert.deepEqual(presetSources('`--preset <name>`, else `default`'), ['flag', 'default'])
    assert.deepEqual(
      presetSources('the `profile` key of `[harness]`, else `--preset <name>`, else `default`'),
      ['profile', 'flag', 'default'],
    )
  },

  'a profile naming no preset stops the build and ship skills instead of falling back — catches an unknown profile swapped for default'() {
    for (const name of ['build', 'ship']) {
      const text = skill(name)
      assert.ok(
        /no `\[build\.presets\.<preset>\]` table[^\n]*\n?[^\n]*stop/i.test(text),
        `${name}: no stop when the resolved preset has no table`,
      )
    }
  },

  'the bootstrap skill offers --profile on both the preview and the apply — catches a profile the preview shows but the apply drops'() {
    const text = skill('bootstrap')
    assert.ok(/"\$SG" bootstrap --profile <name>/.test(text), 'the preview never passes --profile')
    assert.ok(/"\$SG" bootstrap --apply --profile <name>/.test(text), 'the apply never passes --profile')
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
  }
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
