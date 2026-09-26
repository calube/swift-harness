// Scores skill-routing runs from `claude plugin eval --json` results. For each trial it reads the
// kept trace (run the eval with --keep-temp) and records every swift-harness Skill call in order,
// then reports per-skill precision and recall, a confusion table and pass^k.
//
// Run: node evals/runner/routing.mjs <result.json>... [--split 40] [--out <dir>]
//
// The case's tags carry the label: `load-<skill>` or `load-none`, `split-60` or `split-40`,
// `for-<skill>`. Precision and recall count trials, not cases. A trial that loads a skill it
// wasn't expected to is a false positive for that skill, even when it also loads the right one.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const PREFIX = 'swift-harness:'

export function skillCalls(traceText) {
  const calls = []
  const walk = (node) => {
    if (Array.isArray(node)) return node.forEach(walk)
    if (!node || typeof node !== 'object') return
    if (node.type === 'tool_use' && node.name === 'Skill' && typeof node.input?.skill === 'string') {
      calls.push(node.input.skill)
      return
    }
    Object.values(node).forEach(walk)
  }
  for (const line of traceText.split('\n')) {
    if (!line.trim()) continue
    try {
      walk(JSON.parse(line))
    } catch {
      // A partial last line from a killed run carries no complete tool call.
    }
  }
  return calls
}

export function tagsOf(caseYaml) {
  const m = caseYaml.match(/^tags:\s*\[(.*)\]\s*$/m)
  return m ? m[1].split(',').map((t) => t.trim()) : []
}

const tagValue = (tags, prefix) => tags.find((t) => t.startsWith(prefix))?.slice(prefix.length)

// trials: [{ case, forSkill, expect, split, kind, passed, loaded: [skill ids without prefix] }]
export function score(trials) {
  const skills = [...new Set(trials.flatMap((t) => [t.forSkill, t.expect, ...t.loaded]))]
    .filter((s) => s && s !== 'none')
    .sort()
  const perSkill = {}
  for (const s of skills) {
    let tp = 0
    let fn = 0
    let fp = 0
    for (const t of trials) {
      const hit = t.loaded.includes(s)
      if (t.expect === s) hit ? tp++ : fn++
      else if (hit) fp++
    }
    perSkill[s] = {
      expectedTrials: tp + fn,
      loadedTrials: tp + fp,
      tp, fp, fn,
      precision: tp + fp ? tp / (tp + fp) : null,
      recall: tp + fn ? tp / (tp + fn) : null,
    }
  }
  const confusion = {}
  for (const t of trials) {
    const got = t.loaded[0] ?? 'none'
    confusion[t.expect] ??= {}
    confusion[t.expect][got] = (confusion[t.expect][got] ?? 0) + 1
  }
  const byCase = {}
  for (const t of trials) (byCase[t.case] ??= []).push(t)
  const cases = Object.entries(byCase).map(([name, ts]) => ({
    case: name,
    forSkill: ts[0].forSkill,
    kind: ts[0].kind,
    expect: ts[0].expect,
    trials: ts.length,
    passed: ts.filter((t) => t.passed).length,
    loaded: ts.map((t) => t.loaded),
  }))
  const passAll = cases.filter((c) => c.passed === c.trials).length
  const flaky = cases.filter((c) => c.passed > 0 && c.passed < c.trials).map((c) => c.case)
  return { perSkill, confusion, cases, passAllK: passAll, casesTotal: cases.length, flaky }
}

export function collect(resultPaths, split) {
  const trials = []
  let costUsd = 0
  let durationSeconds = 0
  const missingTraces = []
  for (const path of resultPaths) {
    const result = JSON.parse(readFileSync(path, 'utf8'))
    costUsd += result.costUsd ?? 0
    durationSeconds += result.durationSeconds ?? 0
    for (const c of result.cases) {
      const tags = tagsOf(readFileSync(join(result.suite.root, c.dir, 'case.yaml'), 'utf8'))
      const caseSplit = tagValue(tags, 'split-')
      if (split && caseSplit !== String(split)) continue
      for (const run of c.arms.with ?? []) {
        let loaded = []
        if (run.tracePath && existsSync(run.tracePath)) {
          loaded = skillCalls(readFileSync(run.tracePath, 'utf8'))
            .filter((s) => s.startsWith(PREFIX))
            .map((s) => s.slice(PREFIX.length))
        } else {
          missingTraces.push(`${c.name}: ${run.tracePath}`)
        }
        trials.push({
          case: c.name,
          forSkill: tagValue(tags, 'for-'),
          expect: tagValue(tags, 'load-'),
          split: caseSplit,
          kind: tags.includes('near-miss') ? 'near-miss' : 'should-trigger',
          passed: run.passed,
          costUsd: run.costUsd,
          error: run.error ?? null,
          loaded,
        })
      }
    }
  }
  return { trials, costUsd, durationSeconds, missingTraces }
}

const pct = (x) => (x === null ? 'n/a' : x.toFixed(2))

export function markdown(summary) {
  const lines = ['| Skill | Precision | Recall | Expected trials | Loaded trials |', '|---|---|---|---|---|']
  for (const [s, m] of Object.entries(summary.perSkill)) {
    lines.push(`| \`${s}\` | ${pct(m.precision)} | ${pct(m.recall)} | ${m.expectedTrials} | ${m.loadedTrials} |`)
  }
  const cols = [...new Set(Object.values(summary.confusion).flatMap((r) => Object.keys(r)))].sort()
  lines.push('', `| Expected \\ first loaded | ${cols.map((c) => `\`${c}\``).join(' | ')} |`)
  lines.push(`|---|${cols.map(() => '---').join('|')}|`)
  for (const [exp, row] of Object.entries(summary.confusion).sort()) {
    lines.push(`| \`${exp}\` | ${cols.map((c) => row[c] ?? 0).join(' | ')} |`)
  }
  return lines.join('\n')
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2)
  const flag = (name) => {
    const i = args.indexOf(name)
    return i < 0 ? undefined : args.splice(i, 2)[1]
  }
  const split = flag('--split')
  const out = flag('--out')
  const { trials, costUsd, durationSeconds, missingTraces } = collect(args, split)
  const summary = { split: split ?? 'all', trials: trials.length, costUsd, durationSeconds, missingTraces, ...score(trials), trialLog: trials }
  if (out) {
    mkdirSync(out, { recursive: true })
    writeFileSync(join(out, 'routing.json'), JSON.stringify(summary, null, 2) + '\n')
  }
  console.log(markdown(summary))
  console.log(`\npass^k ${summary.passAllK}/${summary.casesTotal} cases; flaky: ${summary.flaky.join(', ') || 'none'}`)
  console.log(`cost ${costUsd.toFixed(2)} USD, wall ${durationSeconds} s, missing traces: ${missingTraces.length}`)
}
