// Checks that a shim test past its own deadline stops, fails naming the deadline, and leaves no
// process under its temp directory.
// Run: node tests/shim_deadline_cleanup_test.mjs
// Regression caught: a shim test that runs on unbounded instead of stopping at its deadline and
// reaping the builds it started, or whose cleanup a late stop signal cuts short.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, processes, reap, runCases, start, survivors, until } from './shim_cleanup.mjs'

const reapDeadline = 10_000

// The shim test's temp directory, read off the command line of the first step that copies the
// harness into it: mktemp picks it and the test never prints it.
function workOf(group) {
  for (const row of processes()) {
    if (row.pgid !== group) continue
    const match = row.command.match(/(\/\S*\/tmp\.[A-Za-z0-9]+)\/repo\//)
    if (match) return match[1]
  }
  return undefined
}

// Waits for the shim test's own deadline report, the line its cleanup prints last, rather than
// for its exit: an exit alone doesn't say whether cleanup got that far.
async function stoppedAtDeadline({ deadline, wait, env = {} }) {
  const run = start({ SHIM_TEST_DEADLINE_SECONDS: String(deadline), ...env })
  const report = new RegExp(`FAIL: shim_test passed its ${deadline}s deadline and was stopped`)
  let closed = false
  run.child.on('close', () => (closed = true))
  let work
  try {
    const reported = await until(() => {
      work ??= workOf(run.child.pid)
      return (report.test(run.output) && run.exit !== undefined) || closed
    }, wait)
    if (!reported || !report.test(run.output)) {
      throw new Error(
        `the shim test did not report passing its ${deadline}s deadline within the ${wait / 1000}s wait ` +
          `(exit ${JSON.stringify(run.exit ?? null)}):\n${run.output}`,
      )
    }
    assert.notEqual(run.exit.code, 0, `the shim test reported its deadline yet exited 0:\n${run.output}`)
    const left = await until(() => (survivors(run.child.pid, work).length === 0 ? [] : undefined), reapDeadline)
    assert.ok(left, `processes still running ${reapDeadline / 1000}s after the shim test stopped:\n${describe(survivors(run.child.pid, work))}`)
  } finally {
    reap(run, work)
  }
}

// An rsync that stalls holds the shim test in its copy step, a foreground command the deadline's
// pkill ends. It keeps its arguments on its command line, so that pkill reaches it, and ends
// itself well after every wait here.
async function withStalledCopy(body) {
  const stall = mkdtempSync(join(tmpdir(), 'shim-stall-'))
  try {
    mkdirSync(join(stall, 'bin'))
    writeFileSync(join(stall, 'bin', 'rsync'), '#!/bin/sh\n/bin/sleep 30\n', { mode: 0o755 })
    await body({ PATH: `${join(stall, 'bin')}:${process.env.PATH}` })
  } finally {
    rmSync(stall, { recursive: true, force: true })
  }
}

await runCases({
  async 'a shim test past its deadline stops, fails naming the deadline, and leaves no process behind — catches a test that runs on unbounded'() {
    await stoppedAtDeadline({ deadline: 6, wait: 25_000 })
  },

  async 'a shim test stopped mid-command at its deadline still reports the deadline and leaves no process behind — catches a late stop signal cutting its cleanup short'() {
    await withStalledCopy((env) => stoppedAtDeadline({ deadline: 3, wait: 15_000, env }))
  },

  async 'a shim test that never reports its deadline fails naming the wait instead of hanging — catches an unbounded wait for the deadline report'() {
    await withStalledCopy((env) =>
      assert.rejects(
        stoppedAtDeadline({ deadline: 600, wait: 2_000, env }),
        /did not report passing its 600s deadline within the 2s wait/,
      ),
    )
  },
})
