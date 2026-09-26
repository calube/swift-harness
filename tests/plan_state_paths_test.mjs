// Checks that the plugin's skills, agents and workflows send a consumer's model to the shared plan
// state under the git common dir, never to a worktree-relative `.harness/plans/` or
// `.harness/orchestrator.lock`. Plan state moved to `$(git rev-parse --git-common-dir)/swift-harness/plans`
// so every worktree reads one index and ledger; a skill still reading the old path finds nothing
// and reports "no plan index" for a repository that has active plans.
// Run: node tests/plan_state_paths_test.mjs
// Regressions caught: a skill, agent or workflow naming the retired path, a status skill that
// stops resolving the common dir, and a scanner that silently stops finding matches.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const plugin = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const SCANNED = ['skills', 'agents', 'workflows']
const RETIRED = /\.harness\/(plans\b|orchestrator\.lock)/

function files(dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...files(path))
    else if (entry.isFile()) out.push(path)
  }
  return out.sort()
}

export function retiredReferences(root, dirs) {
  const hits = []
  for (const dir of dirs) {
    for (const path of files(join(root, dir))) {
      readFileSync(path, 'utf8').split('\n').forEach((line, index) => {
        if (RETIRED.test(line)) hits.push(`${relative(root, path)}:${index + 1}: ${line.trim()}`)
      })
    }
  }
  return hits
}

const tests = {
  'a planted retired path in a nested skill file is found, and only that line — catches a scanner that reports nothing'() {
    const scratch = mkdtempSync(join(tmpdir(), 'plan-state-paths-'))
    try {
      mkdirSync(join(scratch, 'skills', 'x'), { recursive: true })
      writeFileSync(join(scratch, 'skills', 'x', 'SKILL.md'), 'ok: `<common>/swift-harness/plans`\nread `.harness/plans/index.json`\n')
      writeFileSync(join(scratch, 'skills', 'x', 'lock.md'), 'the `.harness/orchestrator.lock` file\n')
      assert.deepEqual(retiredReferences(scratch, ['skills']), [
        'skills/x/SKILL.md:2: read `.harness/plans/index.json`',
        'skills/x/lock.md:1: the `.harness/orchestrator.lock` file',
      ])
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
  },
  'skills, agents and workflows name no worktree-relative plan state — catches a consumer reading a retired path'() {
    assert.deepEqual(retiredReferences(plugin, SCANNED), [])
  },
  'the status skill resolves each repository\'s git common dir — catches it reading an index no worktree shares'() {
    const status = readFileSync(join(plugin, 'skills', 'status', 'SKILL.md'), 'utf8')
    assert.match(status, /git (-C \S+ )?rev-parse --path-format=absolute --git-common-dir/)
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${error.message.split('\n').join('\n     ')}`)
  }
}
if (failed) process.exit(1)
