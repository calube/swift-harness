// The no-model half of guard-conformance: feeds PreToolUse payloads to `swiftgate hook
// pre-tool-use` in a fresh copy of an eval app and compares each decision to its label. The
// live half, where an agent meets the deny, needs a model and runs elsewhere.
//
// Run: node evals/runner/hooks.mjs [evals/corpora/hooks.json] [--out <dir>] [--check]
//   `--check` exits 1 when a `deny` or `control` case disagrees with its label. Evasions have no
//   bar yet, as in checker-accuracy: each one gets a guard, a documented limit or a wontfix.
//   SWIFTGATE points at another checkout's shim, to score a fix branch before it merges.
//
// Each case: { name, kind: deny | control | evasion, expect: deny | allow, tool, input,
//   session?, agent?, env? }. In `input`, $W is the workspace and $PLAN the demo plan's directory
// in the git common dir, whose orchestrator.lock the session `orch` holds.
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const swiftgate = process.env.SWIFTGATE ?? join(root, 'plugin/bin/swiftgate')

function git(cwd, ...args) {
  return execFileSync('git', ['-c', 'user.name=eval', '-c', 'user.email=eval@example.invalid', ...args], { cwd, encoding: 'utf8' }).trim()
}

function workspace() {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), 'hooks-')))
  const ws = join(dir, 'app')
  cpSync(join(root, 'examples/SampleApp'), ws, { recursive: true, filter: (src) => !src.includes('/.harness/runs') })
  git(ws, 'init', '-q', '-b', 'main')
  git(ws, 'add', '-A')
  git(ws, 'commit', '-qm', 'baseline')
  const plan = join(realpathSync(resolve(ws, git(ws, 'rev-parse', '--git-common-dir'))), 'swift-harness/plans/demo')
  mkdirSync(plan, { recursive: true })
  writeFileSync(join(plan, 'orchestrator.lock'), 'orch\n')
  writeFileSync(join(plan, 'ledger.json'), '{}\n')
  return { dir, ws, plan }
}

export function decide(stdout) {
  if (/"permissionDecision"\s*:\s*"deny"/.test(stdout)) return 'deny'
  if (/"permissionDecision"\s*:\s*"ask"/.test(stdout)) return 'ask'
  return 'allow'
}

export function runCorpus(cases) {
  const { dir, ws, plan } = workspace()
  try {
    return cases.map((c) => {
      const input = JSON.parse(JSON.stringify(c.input).replaceAll('$W', ws).replaceAll('$PLAN', plan))
      const payload = { session_id: c.session ?? 'worker', hook_event_name: 'PreToolUse', cwd: ws, tool_name: c.tool, tool_input: input }
      if (c.agent) payload.agent_id = c.agent
      const run = spawnSync(swiftgate, ['hook', 'pre-tool-use'], { cwd: ws, input: JSON.stringify(payload), encoding: 'utf8', env: { ...process.env, ...(c.env ?? {}) } })
      const got = decide(run.stdout)
      return { name: c.name, kind: c.kind, expect: c.expect, got, passed: got === c.expect, exit: run.status }
    })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const out = args.includes('--out') ? args[args.indexOf('--out') + 1] : null
  const file = args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--out') ?? join(root, 'evals/corpora/hooks.json')
  const results = runCorpus(JSON.parse(readFileSync(file, 'utf8')))
  const byKind = {}
  for (const r of results) {
    const k = (byKind[r.kind] ??= { cases: 0, passed: 0 })
    k.cases++
    if (r.passed) k.passed++
  }
  for (const r of results) if (!r.passed) console.log(`MISS ${r.kind} ${r.name}: expect ${r.expect}, got ${r.got}`)
  for (const [k, v] of Object.entries(byKind)) console.log(`${k}: ${v.passed} of ${v.cases} match`)
  if (out) {
    mkdirSync(out, { recursive: true })
    writeFileSync(join(out, 'hooks.json'), JSON.stringify({ swiftgate, byKind, results }, null, 2) + '\n')
  }
  const gating = results.filter((r) => r.kind !== 'evasion' && !r.passed)
  if (args.includes('--check') && gating.length) process.exit(1)
}
