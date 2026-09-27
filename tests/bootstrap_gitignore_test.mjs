// Runs a real `swiftgate bootstrap` dry run in a scratch git repository and reads the .gitignore it
// would stamp. The template is a plain file, so this runs the stamping itself rather than a Swift
// test that `prove` can't revert.
// Run: node tests/bootstrap_gitignore_test.mjs   (SWIFTGATE_BIN=plugin/bin/swiftgate to use the shim)
// Regressions caught: a consumer's .gitignore that leaves the plan skill's drafts (draft ledgers,
// replan inputs, module-graph dumps) showing as untracked files.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')

function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(root, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(root, 'bin/swiftgate')
}

// The lines the dry run's diff adds to .gitignore.
function stampedGitignore() {
  const dir = mkdtempSync(join(tmpdir(), 'bootstrap-gitignore-'))
  try {
    execFileSync('git', ['init', '-q'], { cwd: dir })
    const result = spawnSync(swiftgateBinary(), ['bootstrap'], {
      cwd: dir,
      encoding: 'utf8',
      env: { ...process.env, HOME: dir, LLVM_PROFILE_FILE: join(dir, 'profile-%p.profraw'), SWIFTGATE_HARNESS_ROOT: root },
      timeout: 55_000,
    })
    assert.equal(result.status, 0, result.stdout + result.stderr)
    const hunk = result.stdout.split('\n+++ b/.gitignore\n')[1]
    assert.ok(hunk, `the dry run stamps no .gitignore:\n${result.stdout}`)
    return hunk.split('\n--- ')[0].split('\n').filter(l => l.startsWith('+')).map(l => l.slice(1))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const tests = {
  'the stamped .gitignore ignores the plan skill\'s drafts — catches a draft ledger or module-graph dump showing up as an untracked file'() {
    const lines = stampedGitignore()
    assert.ok(lines.includes('**/.harness/runs/'), `not the .gitignore hunk: ${lines}`)
    assert.ok(lines.includes('**/.harness/plan-draft/'), `.gitignore stamps ${JSON.stringify(lines)}`)
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
