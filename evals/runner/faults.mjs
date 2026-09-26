// Runs the failure-modes cases: each injects 1 fault into a fresh copy of an eval app, runs 1
// swiftgate command, and passes only if the verdict is one its labels allow. A fault case never
// allows GREEN; a control case allows only GREEN, so a gate that blocks everything fails too.
// No model calls.
//
// Run: node evals/runner/faults.mjs [evals/faults/<case> ...] [--out <dir>] [--check]
//   With no case, runs every case under evals/faults. `--check` exits 1 on any failing case.
//   SWIFTGATE points at another checkout's shim, to score a fix branch before it merges.
//
// A case holds `labels.json` and `fault.sh`. labels.json:
//   command   swiftgate arguments, without --json
//   expect    allowed verdicts: ["BLOCKED"], ["RED", "BLOCKED"], or ["GREEN"] for a control
//   rule      optional regex; some finding's rule id must match it
//   base      optional app under examples/, default SampleApp
//   why       what the fault stands for
// fault.sh runs in the workspace after the copy is committed and pushed to its bare origin.
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const swiftgate = process.env.SWIFTGATE ?? join(root, 'plugin/bin/swiftgate')

export function judge(labels, report) {
  const verdictOk = labels.expect.includes(report.verdict)
  const rules = (report.findings ?? []).map((f) => f.rule)
  const ruleOk = !labels.rule || rules.some((r) => new RegExp(labels.rule).test(r))
  return { passed: verdictOk && ruleOk, verdictOk, ruleOk, falseGreen: report.verdict === 'GREEN' && !labels.expect.includes('GREEN') }
}

function git(cwd, ...args) {
  execFileSync('git', ['-c', 'user.name=eval', '-c', 'user.email=eval@example.invalid', ...args], { cwd, stdio: 'pipe' })
}

function workspace(base) {
  const dir = mkdtempSync(join(tmpdir(), 'fault-'))
  const ws = join(dir, 'app')
  cpSync(join(root, 'examples', base), ws, { recursive: true, filter: (src) => !src.includes('/.harness/runs') })
  writeFileSync(join(ws, '.gitignore'), readFileSync(join(root, '.gitignore')))
  git(ws, 'init', '-q', '-b', 'main')
  git(ws, 'add', '-A')
  git(ws, 'commit', '-qm', 'baseline')
  git(dir, 'init', '-q', '--bare', 'origin.git')
  git(ws, 'remote', 'add', 'origin', join(dir, 'origin.git'))
  git(ws, 'push', '-q', 'origin', 'main')
  git(ws, 'fetch', '-q', 'origin')
  return { dir, ws }
}

export function runCase(caseDir) {
  const labels = JSON.parse(readFileSync(join(caseDir, 'labels.json'), 'utf8'))
  const { dir, ws } = workspace(labels.base ?? 'SampleApp')
  const started = Date.now()
  try {
    const fault = spawnSync('bash', [join(caseDir, 'fault.sh')], { cwd: ws, encoding: 'utf8' })
    if (fault.status !== 0) return { case: caseDir, labels, error: `fault.sh exit ${fault.status}: ${fault.stderr.trim().slice(-300)}` }
    const run = spawnSync(swiftgate, [...labels.command, '--json'], { cwd: ws, encoding: 'utf8', maxBuffer: 64 << 20, timeout: 30 * 60 * 1000 })
    let report
    try {
      report = JSON.parse(run.stdout)
    } catch {
      // No report at all is not GREEN: record it as its own verdict so it can't pass a control.
      report = { verdict: 'NO_REPORT', findings: [], stderr: (run.stderr ?? '').slice(-500) }
    }
    const top = (report.findings ?? []).filter((f) => f.severity !== 'nit').slice(0, 3).map((f) => `${f.rule}: ${f.message.slice(0, 160)}`)
    return { case: caseDir, labels, verdict: report.verdict, exit: run.status, top, seconds: Math.round((Date.now() - started) / 1000), ...judge(labels, report) }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const out = args.includes('--out') ? args[args.indexOf('--out') + 1] : null
  const check = args.includes('--check')
  let cases = args.filter((a, i) => !a.startsWith('--') && args[i - 1] !== '--out')
  if (!cases.length) cases = readdirSync(join(root, 'evals/faults')).map((c) => join(root, 'evals/faults', c)).filter((c) => existsSync(join(c, 'labels.json')))
  // Build the gate before the first case, so no case's timing or verdict includes the build.
  execFileSync(swiftgate, ['--version'], { stdio: 'pipe' })
  const results = []
  for (const c of cases) {
    const r = runCase(resolve(c))
    results.push(r)
    const name = r.case.split('/').pop()
    console.log(`${r.passed ? 'PASS' : 'FAIL'} ${name}: ${r.error ?? `${r.verdict} (expect ${r.labels.expect.join('|')}${r.labels.rule ? `, rule ${r.labels.rule}` : ''}) ${r.seconds}s`}`)
    for (const t of r.top ?? []) console.log(`     ${t}`)
  }
  const faults = results.filter((r) => !r.labels.expect.includes('GREEN'))
  const summary = {
    cases: results.length,
    passed: results.filter((r) => r.passed).length,
    falseGreens: results.filter((r) => r.falseGreen).map((r) => r.case.split('/').pop()),
    faultCases: faults.length,
    controls: results.length - faults.length,
  }
  console.log(`\n${summary.passed} of ${summary.cases} pass; false greens: ${summary.falseGreens.length ? summary.falseGreens.join(', ') : 'none'}`)
  if (out) {
    mkdirSync(out, { recursive: true })
    writeFileSync(join(out, 'faults.json'), JSON.stringify({ swiftgate, summary, results: results.map((r) => ({ ...r, case: r.case.split('/').pop() })) }, null, 2) + '\n')
  }
  if (check && summary.passed !== summary.cases) process.exit(1)
}
