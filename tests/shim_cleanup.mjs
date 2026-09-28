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

// Whatever the outcome, this test must not itself be the thing that leaks.
export function reap(run, work) {
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
