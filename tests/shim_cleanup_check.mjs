// Checks that tests/shim_test.sh never leaves a process running once it has ended. A cold hook
// starts a detached `swift build` that runs for minutes, and a shim test that dies early (killed by
// a harness timeout, or past its own deadline) must not leave it running with no parent.
// Run: node tests/shim_cleanup_check.mjs. It is not a `_test.mjs`: each case starts a real cold
// build, which under a loaded `swift test` outruns the 60s every discovered script gets, so
// RepositoryScriptTests runs it on its own, longer timeout.
// Regressions caught: a detached cold build outliving a shim test that was killed outright, and a
// shim test that runs on past its own deadline instead of stopping and reaping what it started.
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const checkout = join(dirname(fileURLToPath(import.meta.url)), '..')
const script = join(checkout, 'tests/shim_test.sh')

const pause = (ms) => new Promise((done) => setTimeout(done, ms))

function processes() {
  // Compiler command lines run to hundreds of KB each, far past spawnSync's 1 MB default.
  const result = spawnSync('ps', ['-axww', '-o', 'pid=,pgid=,command='], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
  })
  if (result.error || result.status !== 0) throw new Error(`ps failed: ${result.error?.message ?? result.stderr}`)
  return result.stdout.split('\n').flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)
    return match ? [{ pid: Number(match[1]), pgid: Number(match[2]), command: match[3] }] : []
  })
}

// The shim test's temp directory, read off the command line of the first shim it runs: the test
// never prints it, and mktemp picks it.
function workDirectory(group) {
  for (const row of processes()) {
    if (row.pgid !== group) continue
    const match = row.command.match(/(\/\S*\/tmp\.[A-Za-z0-9]+)\/repo\/plugin\/bin\/swiftgate/)
    if (match) return match[1]
  }
  return undefined
}

// Every process still in the test's process group, or naming its temp directory under either
// spelling (/var and its /private/var target on macOS), since a compiler job runs in a group of
// its own.
function survivors(group, work) {
  const tag = work ? `/${work.split('/').pop()}/` : undefined
  return processes().filter(
    (row) => row.pid !== process.pid && (row.pgid === group || (tag !== undefined && row.command.includes(tag))),
  )
}

async function until(predicate, ms) {
  const end = Date.now() + ms
  for (;;) {
    const value = predicate()
    if (value || Date.now() >= end) return value
    await pause(100)
  }
}

function start(env = {}) {
  const child = spawn('bash', [script], {
    cwd: checkout,
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, ...env },
  })
  const run = { child, output: '', exit: undefined }
  child.stdout.on('data', (chunk) => (run.output += chunk))
  child.stderr.on('data', (chunk) => (run.output += chunk))
  run.exited = new Promise((done) => child.on('exit', (code, signal) => done((run.exit = { code, signal }))))
  return run
}

// Whatever the outcome, this test must not itself be the thing that leaks.
function reap(run, work) {
  for (const row of survivors(run.child.pid, work)) {
    try {
      process.kill(row.pid, 'SIGKILL')
    } catch {}
  }
  if (work) {
    rmSync(work, { recursive: true, force: true })
    rmSync(work.replace(/^\/private\//, '/'), { recursive: true, force: true })
  }
}

const describe = (rows) => rows.map((row) => `${row.pid} ${row.command.slice(0, 160)}`).join('\n')

const tests = {
  async 'a shim test killed outright leaves no process under its temp directory — catches a detached cold build outliving a test the harness killed'() {
    const run = start()
    let work
    try {
      work = await until(() => workDirectory(run.child.pid), 60_000)
      assert.ok(work, `the shim test ran no shim within 60s:\n${run.output}`)
      process.kill(run.child.pid, 'SIGKILL')
      await run.exited
      const left = await until(() => {
        const rows = survivors(run.child.pid, work)
        return rows.length === 0 ? [] : undefined
      }, 30_000)
      assert.ok(left, `processes still running 30s after the shim test was killed:\n${describe(survivors(run.child.pid, work))}`)
    } finally {
      reap(run, work)
    }
  },
  async 'a shim test past its deadline stops, fails naming the deadline, and leaves no process behind — catches a test that runs on unbounded'() {
    const run = start({ SHIM_TEST_DEADLINE_SECONDS: '6' })
    let work
    try {
      work = await until(() => workDirectory(run.child.pid) ?? run.exit, 60_000)
      if (typeof work !== 'string') work = undefined
      const exit = await Promise.race([run.exited, pause(60_000)])
      assert.ok(exit, `the shim test was still running 60s after a 6s deadline:\n${run.output}`)
      assert.notEqual(exit.code, 0, `the shim test passed its deadline yet exited 0:\n${run.output}`)
      assert.match(run.output, /deadline/, 'the shim test did not say it hit its deadline')
      const left = await until(() => (survivors(run.child.pid, work).length === 0 ? [] : undefined), 10_000)
      assert.ok(left, `processes still running after the shim test stopped:\n${describe(survivors(run.child.pid, work))}`)
    } finally {
      reap(run, work)
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
