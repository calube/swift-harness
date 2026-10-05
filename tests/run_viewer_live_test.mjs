// Starts the real `swiftgate view --ensure` on a scratch repository holding the captured build run
// with its final gate held back, so the run is still going, and drives the live page in headless
// Chrome: the final gate appended to the run's ledger log reaches the page on its next poll, and
// once the run's `finish` lands and its final report is written, the page shows the end banner
// linking `/final`, which serves that report. A second `--ensure` gets the same URL and server, and
// `SWIFTGATE_VIEW=off` starts nothing and prints no URL.
// Run: node tests/run_viewer_live_test.mjs   (SWIFTGATE_BIN=plugin/bin/swiftgate to use the shim)
// Regressions caught: a second server or a new URL on each build start, an off switch that still
// starts one, a live page that misses an appended event, and a finished run with no way to its
// final report.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { appendFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gitPath } from './developer_tools.mjs'
import { findChrome, launch } from './headless_chrome.mjs'

const plugin = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const captured = join(plugin, 'gate/Tests/Fixtures/RunView/build-run-1')
const BUILD_RUN = '20261004T045528Z-58d28c78'
const PLAN = '2026-10-03-counter-reset-and-floor'

function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(plugin, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(plugin, 'bin/swiftgate')
}

if (!findChrome()) {
  console.log('skip run viewer live checks: no Chrome binary (set CHROME_PATH)')
  process.exit(0)
}

// The captured run's plan state and stores, its ledger log without its last line, the final gate.
const dir = mkdtempSync(join(tmpdir(), 'run-viewer-live-'))
execFileSync(gitPath, ['init', '-q'], { cwd: dir })
writeFileSync(join(dir, '.swiftgate.toml'), '')
const planDir = join(dir, '.git/swift-harness/plans', PLAN)
const runDir = join(planDir, 'build', BUILD_RUN)
mkdirSync(runDir, { recursive: true })
mkdirSync(join(dir, '.harness'), { recursive: true })
for (const [from, to] of [
  ['ledger.json', join(planDir, 'ledger.json')],
  ['plan.json', join(planDir, 'plan.json')],
  ['plan.md', join(planDir, 'spec-page.md')],
  ['run.json', join(runDir, 'run.json')],
  ['returns', join(runDir, 'returns')],
  ['events', join(dir, '.harness/events')],
  ['runs', join(dir, '.harness/runs')],
]) cpSync(join(captured, from), to, { recursive: true })
const ledgerLines = readFileSync(join(captured, 'ledger-events.jsonl'), 'utf8').split('\n').filter(Boolean)
const finalGate = ledgerLines[ledgerLines.length - 1]
assert.match(finalGate, /"gate":"final"/, 'the capture no longer ends with the final gate')
const ledgerLog = join(runDir, 'events.jsonl')
writeFileSync(ledgerLog, ledgerLines.slice(0, -1).map((l) => l + '\n').join(''))

const env = { ...process.env, SWIFTGATE_HARNESS_ROOT: plugin, LLVM_PROFILE_FILE: join(dir, 'profile-%p.profraw') }
delete env.SWIFTGATE_VIEW
const swiftgate = (args, extra = {}) => spawnSync(swiftgateBinary(), args, {
  cwd: dir, encoding: 'utf8', env: { ...env, ...extra }, timeout: 60_000,
})
const record = () => JSON.parse(readFileSync(join(dir, '.git/swift-harness/view-server.json'), 'utf8'))

// Resolves once `condition` holds on the page, read on every DOM change; the page's own poll
// drives the changes, so nothing here sleeps.
const until = (condition, ms = 15000) => `new Promise((resolve, reject) => {
  const check = () => { const v = (${condition}); if (v) { observer.disconnect(); clearTimeout(timer); resolve(v) } }
  const observer = new MutationObserver(check)
  const timer = setTimeout(() => { observer.disconnect(); reject(new Error(${JSON.stringify('timed out waiting for: ' + condition)})) }, ${ms})
  observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, characterData: true })
  check()
})`
const gateRows = `document.querySelectorAll('#gate-list .gate').length`

let server = null
let failed = 0
const tests = {
  'view --ensure starts 1 detached server, prints its URL alone, and a second call gets the same URL and pid — catches a new server and URL on every build start'() {
    const first = swiftgate(['view', '--ensure'])
    assert.equal(first.status, 0, first.stdout + first.stderr)
    const url = first.stdout.trim()
    assert.match(url, /^http:\/\/127\.0\.0\.1:\d+\/$/)
    server = record()
    assert.equal(url, `http://127.0.0.1:${server.port}/`)
    const second = swiftgate(['view', '--ensure'])
    assert.equal(second.status, 0, second.stdout + second.stderr)
    assert.equal(second.stdout.trim(), url)
    assert.deepEqual(record(), server, 'the second call started another server')
    server.url = url
  },

  'SWIFTGATE_VIEW=off prints no URL, starts nothing and says why on stderr — catches an off switch that still starts a server'() {
    const off = swiftgate(['view', '--ensure'], { SWIFTGATE_VIEW: 'off' })
    assert.equal(off.status, 0, off.stderr)
    assert.equal(off.stdout, '')
    assert.match(off.stderr, /SWIFTGATE_VIEW=off/)
    assert.equal(record().pid, server.pid)
  },

  async 'the live page draws the running run, shows the appended final gate on its next poll, and once the run finishes and its report is written shows the end banner whose link serves the final report — catches a live page that misses a change or never says its run ended'() {
    const { page, close } = await launch({ deadlineMs: 60000 })
    try {
      await page.load(server.url)
      await page.evaluate(until(`document.getElementById('state').textContent === 'running'`))
      const before = await page.evaluate(gateRows)
      assert.equal(await page.evaluate("document.getElementById('end-banner')?.hidden ?? true"), true)

      appendFileSync(ledgerLog, finalGate + '\n')
      await page.evaluate(until(`document.getElementById('state').textContent === 'done' && ${gateRows} === ${before + 1}`))
      assert.equal(await page.evaluate("document.getElementById('end-banner').hidden"), true, 'the banner shows before the final report exists')

      appendFileSync(ledgerLog, JSON.stringify({ at: '2026-10-04T05:19:40Z', kind: 'finish' }) + '\n')
      const report = swiftgate(['report', '--html', BUILD_RUN])
      assert.equal(report.status, 0, report.stdout + report.stderr)
      const banner = await page.evaluate(until("(() => { const b = document.getElementById('end-banner'); return b && !b.hidden && b.textContent })()"))
      assert.match(banner, /finished/i)
      assert.equal(await page.evaluate("document.getElementById('state').textContent"), 'done')
      const href = await page.evaluate("document.querySelector('#end-banner a').href")
      assert.equal(new URL(href).pathname, '/final')
      const final = await fetch(href)
      assert.equal(final.status, 200)
      assert.equal(await final.text(), readFileSync(join(dir, '.harness/reports', BUILD_RUN, 'index.html'), 'utf8'))
      assert.equal(await page.evaluate('document.body.dataset.errors'), '0')
      // The browser asks for a favicon, which the server 404s.
      assert.deepEqual(page.errors.filter((e) => !/status of 404/.test(e)), [])
    } finally {
      await close()
    }
  },
}

try {
  for (const [name, test] of Object.entries(tests)) {
    try {
      await test()
      console.log(`ok   ${name}`)
    } catch (error) {
      failed++
      console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
      if (!server) break
    }
  }
} finally {
  // The server is detached on purpose; this test stops the 1 it started, by its saved pid.
  try { const pid = record().pid; if (Number.isInteger(pid) && pid > 1) process.kill(pid, 'SIGTERM') } catch {}
  rmSync(dir, { recursive: true, force: true })
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
