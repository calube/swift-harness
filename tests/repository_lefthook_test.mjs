// Checks this repository's own root `lefthook.yml`, the contributor hooks. Without it the plugin
// repo ran no pre-push gate at all, so `check --tier push` and the commit-msg comments check only
// ran when someone remembered to, unlike every consumer repository bootstrap stamps.
// Run: node tests/repository_lefthook_test.mjs
// Regressions caught: pre-push or commit-msg unwired or pointed at the wrong command, YAML that
// reads right but lefthook itself rejects, and AGENTS.md no longer telling contributors to install it.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const checkout = join(dirname(fileURLToPath(import.meta.url)), '..')

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8' })
  if (result.error) throw new Error(`${command} could not run: ${result.error.message}`)
  assert.equal(result.status, 0, `${command} ${args.join(' ')} failed:\n${result.stdout}${result.stderr}`)
  return result
}

const tests = {
  'pre-push runs the push tier and commit-msg runs the comments check, both through the in-repo shim — catches the contributor gate silently unwired'() {
    const text = readFileSync(join(checkout, 'lefthook.yml'), 'utf8')
    assert.match(text, /^pre-push:\n {2}commands:\n {4}[\w-]+:\n {6}run: '"plugin\/bin\/swiftgate" check --tier push'$/m)
    assert.match(text, /^commit-msg:\n {2}commands:\n {4}[\w-]+:\n {6}run: '"plugin\/bin\/swiftgate" comments --commit-msg \{1\}'$/m)
  },
  'AGENTS.md tells contributors to run lefthook install — catches a checkout whose hooks are never installed'() {
    assert.match(readFileSync(join(checkout, 'AGENTS.md'), 'utf8'), /`lefthook install`/)
  },
  'lefthook install on this lefthook.yml writes the pre-push and commit-msg hooks — catches YAML that looks right but lefthook rejects'() {
    const scratch = mkdtempSync(join(tmpdir(), 'repository-lefthook-'))
    try {
      run('git', ['init', '-q'], scratch)
      copyFileSync(join(checkout, 'lefthook.yml'), join(scratch, 'lefthook.yml'))
      run('lefthook', ['install'], scratch)
      for (const hook of ['pre-push', 'commit-msg']) {
        const path = join(scratch, '.git', 'hooks', hook)
        assert.ok(existsSync(path), `lefthook installed no ${hook} hook`)
        assert.match(readFileSync(path, 'utf8'), /lefthook/, `${hook} does not run lefthook`)
      }
    } finally {
      rmSync(scratch, { recursive: true, force: true })
    }
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
