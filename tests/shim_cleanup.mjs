// Shared by the shim cleanup tests: starts tests/shim_test.sh in a process group of its own and
// finds every process it left behind. A cold hook starts a detached `swift build` that runs for
// minutes, and a shim test that dies early must not leave it running with no parent. Each case
// lives in its own `_test.mjs` so it gets the full 60s a repository script is given.
import { spawn, spawnSync } from 'node:child_process'
import { rmSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const checkout = join(dirname(fileURLToPath(import.meta.url)), '..')
const script = join(checkout, 'tests/shim_test.sh')

export const pause = (ms) => new Promise((done) => setTimeout(done, ms))

export function processes() {
  // Compiler command lines run to hundreds of KB each, far past spawnSync's 1 MB default.
  const result = spawnSync('ps', ['-axww', '-o', 'pid=,pgid=,state=,command='], {
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
  })
  if (result.error || result.status !== 0) throw new Error(`ps failed: ${result.error?.message ?? result.stderr}`)
  return result.stdout.split('\n').flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/)
    return match ? [{ pid: Number(match[1]), pgid: Number(match[2]), state: match[3], command: match[4] }] : []
  })
}

// The shim test's temp directory, read off the command line of the first shim it runs: the test
// never prints it, and mktemp picks it.
export function workDirectory(group) {
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
export function survivors(group, work) {
  const tag = work ? `/${work.split('/').pop()}/` : undefined
  return processes().filter(
    (row) => row.pid !== process.pid && (row.pgid === group || (tag !== undefined && row.command.includes(tag))),
  )
}

export async function until(predicate, ms) {
  const end = Date.now() + ms
  for (;;) {
    const value = predicate()
    if (value || Date.now() >= end) return value
    await pause(100)
  }
}

export function start(env = {}) {
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

// How long every process reap kills has to exit before its temp directory is removed.
const exitDeadline = 10_000

// Registers each pid for kqueue's NOTE_EXIT before sending it SIGKILL, then waits on those exits
// until the deadline. A killed process can still finish the write it is in, so the temp directory
// is only safe to remove once the kernel says it has exited.
const killAndAwaitExit = `
import os, select, signal, sys, time
queue = select.kqueue()
watched = 0
for pid in map(int, sys.argv[2:]):
    try:
        queue.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT, select.KQ_NOTE_EXIT)], 0)
    except ProcessLookupError:
        continue
    watched += 1
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
end = time.monotonic() + float(sys.argv[1])
while watched > 0 and time.monotonic() < end:
    watched -= len(queue.control(None, watched, max(0, end - time.monotonic())))
`

// Whatever the outcome, this test must not itself be the thing that leaks. A process killed after
// the listing may have started another, so each round kills whatever is still listed. A zombie has
// exited and writes nothing, so it is not waited on. A cleanup failure is appended to the case's
// own failure when there is one, since an error thrown from a `finally` would replace it.
export function reap(run, work, failure) {
  const end = Date.now() + exitDeadline
  let left = []
  for (;;) {
    left = survivors(run.child.pid, work).filter((row) => !row.state.startsWith('Z'))
    if (left.length === 0 || Date.now() >= end) break
    const result = spawnSync(
      'python3',
      ['-c', killAndAwaitExit, String((end - Date.now()) / 1000), ...left.map((row) => String(row.pid))],
      { encoding: 'utf8' },
    )
    if (result.error || result.status !== 0) {
      throw new Error(`waiting on killed processes failed: ${result.error?.message ?? result.stderr}`)
    }
  }
  let problem
  if (left.length > 0) {
    problem = `processes still running ${exitDeadline / 1000}s after being killed, so the temp directory was left:\n${describe(left)}`
  } else if (work) {
    try {
      rmSync(work, { recursive: true, force: true })
      rmSync(work.replace(/^\/private\//, '/'), { recursive: true, force: true })
    } catch (error) {
      problem = `removing the temp directory failed after every process under it exited: ${error.message}`
    }
  }
  if (problem === undefined) return
  if (failure === undefined) throw new Error(problem)
  failure.message += `\ncleanup also failed: ${problem}`
}

export const describe = (rows) => rows.map((row) => `${row.pid} ${row.command.slice(0, 160)}`).join('\n')

export async function runCases(tests) {
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
}
