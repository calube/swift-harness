// Checks that a shim test killed outright (SIGKILL, as a harness timeout can) leaves no process
// under its temp directory: its watchdog must reap the detached cold build it started.
// Run: node tests/shim_kill_cleanup_test.mjs
// Regression caught: a detached cold build running on with no parent for minutes after the shim
// test that started it was killed.
import assert from 'node:assert/strict'
import { describe, pause, reap, runCases, start, survivors, until, workDirectory } from './shim_cleanup.mjs'

await runCases({
  async 'a shim test killed outright leaves no process under its temp directory — catches a detached cold build outliving a test the harness killed'() {
    const run = start()
    let work
    try {
      work = await until(() => workDirectory(run.child.pid), 20_000)
      assert.ok(work, `the shim test ran no shim within 20s:\n${run.output}`)
      process.kill(run.child.pid, 'SIGKILL')
      await run.exited
      const left = await until(() => (survivors(run.child.pid, work).length === 0 ? [] : undefined), 25_000)
      assert.ok(left, `processes still running 25s after the shim test was killed:\n${describe(survivors(run.child.pid, work))}`)
    } finally {
      reap(run, work)
    }
  },
})
