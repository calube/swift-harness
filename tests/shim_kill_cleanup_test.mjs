// Checks that a shim test killed outright (SIGKILL, as a harness timeout can) leaves no process
// under its temp directory: its watchdog must reap the detached cold build it started.
// Run: node tests/shim_kill_cleanup_test.mjs
// Regression caught: a detached cold build running on with no parent for minutes after the shim
// test that started it was killed.
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, processes, reap, runCases, start, survivors, until } from './shim_cleanup.mjs'

// The shim test copies the whole gate package before its first cold hook takes the build lock,
// and under a loaded full test run that start has run past 20s. The wait is sized for a cold start
// under load while leaving the reap check its share of the 60s a script is given.
const coldBuildDeadline = 30_000
const reapDeadline = 20_000

// The shim test's temp directory, read off the command line of the first step that copies the
// harness into it: mktemp picks it and the test never prints it. The copy runs well before the
// first shim, so a slow start still shows which step it reached.
function workOf(group) {
  for (const row of processes()) {
    if (row.pgid !== group) continue
    const match = row.command.match(/(\/\S*\/tmp\.[A-Za-z0-9]+)\/repo\//)
    if (match) return match[1]
  }
  return undefined
}

// The first cold hook takes `building-<hash>` in the shim test's data directory just before it
// detaches the build, so the lock is the build's own start, read off the disk without scanning
// the process table. Each sample empties the data directory, so a missing one is not an error.
function coldBuildLock(work) {
  try {
    return readdirSync(join(work, 'plugin-data')).some((entry) => entry.startsWith('building-'))
  } catch (error) {
    if (error.code === 'ENOENT') return false
    throw error
  }
}

async function coldBuildStarted(run, deadline) {
  let work
  const started = await until(() => {
    work ??= workOf(run.child.pid)
    return (work !== undefined && coldBuildLock(work)) || run.exit !== undefined
  }, deadline)
  if (started && run.exit === undefined) return work
  const reached =
    run.exit !== undefined
      ? `the shim test exited first (${JSON.stringify(run.exit)})`
      : work
        ? 'it was copying into its temp directory but took no build lock'
        : 'no copy into a temp directory was seen'
  throw Object.assign(
    new Error(`the shim test started no cold build within the ${deadline / 1000}s cold-build deadline: ${reached}\n${run.output}`),
    { work },
  )
}

async function killedShimTest({ env = {}, deadline = coldBuildDeadline } = {}) {
  const run = start(env)
  let work
  try {
    try {
      work = await coldBuildStarted(run, deadline)
    } catch (error) {
      work = error.work
      throw error
    }
    process.kill(run.child.pid, 'SIGKILL')
    await run.exited
    const left = await until(() => (survivors(run.child.pid, work).length === 0 ? [] : undefined), reapDeadline)
    assert.ok(left, `processes still running ${reapDeadline / 1000}s after the shim test was killed:\n${describe(survivors(run.child.pid, work))}`)
  } finally {
    reap(run, work)
  }
}

await runCases({
  async 'a shim test that never reaches a shim fails naming the cold-build deadline instead of hanging — catches an unbounded wait for the cold build'() {
    // An rsync that stalls holds the shim test in its copy step, before any shim runs. It keeps
    // its arguments on its command line so the copy is seen, and ends itself well after the
    // deadline so nothing depends on this test's reap.
    const stall = mkdtempSync(join(tmpdir(), 'shim-stall-'))
    try {
      mkdirSync(join(stall, 'bin'))
      writeFileSync(join(stall, 'bin', 'rsync'), '#!/bin/sh\n/bin/sleep 20\n', { mode: 0o755 })
      await assert.rejects(
        killedShimTest({ env: { PATH: `${join(stall, 'bin')}:${process.env.PATH}` }, deadline: 2_000 }),
        /started no cold build within the 2s cold-build deadline/,
      )
    } finally {
      rmSync(stall, { recursive: true, force: true })
    }
  },

  async 'a shim test killed outright leaves no process under its temp directory — catches a detached cold build outliving a test the harness killed'() {
    await killedShimTest()
  },
})
