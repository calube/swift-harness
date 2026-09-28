// Checks that a shim test past its own deadline stops, fails naming the deadline, and leaves no
// process under its temp directory.
// Run: node tests/shim_deadline_cleanup_test.mjs
// Regression caught: a shim test that runs on unbounded instead of stopping at its deadline and
// reaping the builds it started.
import assert from 'node:assert/strict'
import { describe, pause, reap, runCases, start, survivors, until, workDirectory } from './shim_cleanup.mjs'

await runCases({
  async 'a shim test past its deadline stops, fails naming the deadline, and leaves no process behind — catches a test that runs on unbounded'() {
    const run = start({ SHIM_TEST_DEADLINE_SECONDS: '6' })
    let work
    try {
      const exit = await until(() => {
        work ??= workDirectory(run.child.pid)
        return run.exit
      }, 40_000)
      assert.ok(exit, `the shim test was still running 40s after starting with a 6s deadline:\n${run.output}`)
      assert.notEqual(exit.code, 0, `the shim test passed its deadline yet exited 0:\n${run.output}`)
      assert.match(run.output, /deadline/, 'the shim test did not say it hit its deadline')
      const left = await until(() => (survivors(run.child.pid, work).length === 0 ? [] : undefined), 10_000)
      assert.ok(left, `processes still running after the shim test stopped:\n${describe(survivors(run.child.pid, work))}`)
    } finally {
      reap(run, work)
    }
  },
})
