// Checks that the git the repository scripts launch skips Apple's xcrun shim.
// Run: node tests/developer_tools_test.mjs
// Regression caught: a script's git launched through /usr/bin/git, whose shared xcrun lookup
// cache a concurrent swift launch can turn into swift.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { gitPath } from './developer_tools.mjs'

const tests = {
  'the scripts\' git runs with no xcrun lookup — catches a concurrent swift launch turning a test\'s git into swift'() {
    // The shim prints its lookup under `xcrun_verbose`; git itself ignores the variable.
    const result = spawnSync(gitPath, ['--version'], { encoding: 'utf8', env: { ...process.env, xcrun_verbose: '1' } })
    assert.equal(result.status, 0, `${gitPath} --version failed: ${result.error?.message ?? result.stderr}`)
    assert.match(result.stdout, /^git version/)
    assert.doesNotMatch(result.stderr, /xcrun_db/, `${gitPath} went through the xcrun lookup:\n${result.stderr}`)
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
