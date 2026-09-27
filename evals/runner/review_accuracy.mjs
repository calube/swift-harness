// Scores review-accuracy trials: matches the kept review artifacts of each trial to its case's
// seeded defects by file and line range. No model calls.
//
// Run: node evals/runner/review_accuracy.mjs <raw-dir> [--out <dir>]
//   <raw-dir> is session.mjs --raw; each trial's kept/ holds review-findings/*.json and review.json.
//
// A finding matches a seeded defect when it names the defect's file and a line within `slack`
// lines of its range. "Before the verifier" counts every finding the reviewers returned; "after"
// counts the findings review-synth kept in review.json. Unmatched findings are listed for a person
// to label `real` (added to the case's `known` list) or `invented`; a finding that matches a
// `known` entry counts as real.
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const slack = 3

export function matches(finding, target) {
  if (finding.file !== target.file || finding.line == null) return false
  const [start, end] = target.lines
  return finding.line >= start - slack && finding.line <= end + slack
}

const blocking = (f) => f.severity === 'blocker' || f.severity === 'major'

function findRuns(dir) {
  const out = []
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (!e.isDirectory()) continue
      const p = join(d, e.name)
      if (e.name === 'runs' && d.endsWith('.harness')) {
        for (const r of readdirSync(p)) if (existsSync(join(p, r, 'review.json'))) out.push(join(p, r))
      } else walk(p)
    }
  }
  walk(dir)
  return out
}

export function scoreTrial(labels, runDir) {
  const fdir = join(runDir, 'review-findings')
  const pre = existsSync(fdir)
    ? readdirSync(fdir).flatMap((f) => (JSON.parse(readFileSync(join(fdir, f), 'utf8')).findings ?? []).map((x) => ({ ...x, focus: f.replace(/\.json$/, '') })))
    : []
  const report = JSON.parse(readFileSync(join(runDir, 'review.json'), 'utf8'))
  const post = (report.findings ?? []).map((m) => ({ ...m.finding, focuses: m.focuses }))
  const known = labels.known ?? []
  const judge = (list) => {
    const seeded = labels.defects.map((d) => {
      const hits = list.filter((f) => matches(f, d))
      return { id: d.id, found: hits.length > 0, blocking: hits.some(blocking), severities: hits.map((h) => h.severity) }
    })
    const other = list.filter((f) => !labels.defects.some((d) => matches(f, d)))
    const real = other.filter((f) => known.some((k) => matches(f, k)))
    const unlabelled = other.filter((f) => !known.some((k) => matches(f, k)))
    return { count: list.length, seeded, real: real.length, unlabelled }
  }
  // A seeded case passes on any verdict that stops the merge; which one depends on whether the
  // panel reads the fix as local (fix-then-merge) or structural (refactor-needed).
  const expected = labels.defects.length ? ['fix-then-merge', 'refactor-needed'] : ['merge']
  return { verdict: report.verdict, expectedVerdict: expected.join(' or '), verdictOk: expected.includes(report.verdict), dropped: (report.dropped ?? []).length, before: judge(pre), after: judge(post) }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const out = args.includes('--out') ? args[args.indexOf('--out') + 1] : null
  const raw = resolve(args.find((a, i) => !a.startsWith('--') && args[i - 1] !== '--out'))
  const rows = []
  for (const caseDir of readdirSync(raw)) {
    const name = caseDir.replace(/^review-/, '')
    const labelsPath = join(root, 'evals/sessions/review', name, 'labels.json')
    if (!existsSync(labelsPath)) continue
    const labels = JSON.parse(readFileSync(labelsPath, 'utf8'))
    for (const trial of readdirSync(join(raw, caseDir))) {
      const runs = findRuns(join(raw, caseDir, trial))
      if (!runs.length) { rows.push({ case: name, trial, error: 'no review.json kept' }); continue }
      rows.push({ case: name, trial, ...scoreTrial(labels, runs.at(-1)) })
    }
  }
  const seeded = rows.flatMap((r) => r.after?.seeded ?? [])
  const seededBefore = rows.flatMap((r) => r.before?.seeded ?? [])
  const totals = {
    trials: rows.length,
    errors: rows.filter((r) => r.error).length,
    recallBefore: `${seededBefore.filter((s) => s.found).length} of ${seededBefore.length}`,
    recallAfter: `${seeded.filter((s) => s.found).length} of ${seeded.length}`,
    recallAfterBlocking: `${seeded.filter((s) => s.blocking).length} of ${seeded.length}`,
    verdictsRight: `${rows.filter((r) => r.verdictOk).length} of ${rows.filter((r) => !r.error).length}`,
    findingsBefore: rows.reduce((s, r) => s + (r.before?.count ?? 0), 0),
    findingsAfter: rows.reduce((s, r) => s + (r.after?.count ?? 0), 0),
    unlabelledAfter: rows.reduce((s, r) => s + (r.after?.unlabelled.length ?? 0), 0),
  }
  for (const r of rows) {
    if (r.error) { console.log(`${r.case} ${r.trial}: ${r.error}`); continue }
    const s = r.after.seeded.map((x) => `${x.id} ${x.found ? (x.blocking ? 'FOUND' : 'found-low') : 'MISSED'}`).join(', ') || 'clean'
    console.log(`${r.case} ${r.trial}: verdict ${r.verdict}${r.verdictOk ? '' : ` (expected ${r.expectedVerdict})`}; ${s}; findings ${r.before.count} before, ${r.after.count} after, ${r.after.unlabelled.length} to label`)
    for (const u of r.after.unlabelled) console.log(`    label? ${u.severity} ${u.file}:${u.line} [${u.category}] ${u.title}`)
  }
  console.log(JSON.stringify(totals))
  if (out) { mkdirSync(out, { recursive: true }); writeFileSync(join(out, 'review-accuracy.json'), JSON.stringify({ totals, rows }, null, 2) + '\n') }
}
