// Runs rule corpora through swiftgate and scores its rule ids against each case's labels.
// Run: node evals/runner/corpus.mjs evals/corpora/prose [evals/corpora/lint ...] [--out <dir>]
//        [--drop-rule <id> ...] [--check]
// `--check` exits 1 when a positive, near-miss or clean case disagrees with its labels.
//
// A corpus directory is named for the swiftgate command it exercises (`prose`, `lint`, `arch`).
// Each case under it holds `labels.json` and its inputs:
//   prose: `*.md` files, or `"paths"` in labels.json naming repo files checked in place;
//   lint, arch: `files/`, overlaid onto a fresh copy of `"base"` (default examples/SampleApp).
// The runner never parses Swift or markdown itself; it only compares rule ids.
//
// `--drop-rule` removes a rule's findings before scoring. It plants a gate break for the
// "evals catch a broken harness" check without touching gate/.
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const KINDS = ['positive', 'evasion', 'near-miss', 'clean']

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const swiftgate = join(root, 'bin/swiftgate')

export function loadCases(corpusDir) {
  const gate = basename(corpusDir)
  return readdirSync(corpusDir)
    .filter((name) => existsSync(join(corpusDir, name, 'labels.json')))
    .sort()
    .map((name) => {
      const dir = join(corpusDir, name)
      const labels = JSON.parse(readFileSync(join(dir, 'labels.json'), 'utf8'))
      if (!KINDS.includes(labels.kind)) throw new Error(`${dir}: kind must be one of ${KINDS.join(', ')}`)
      if (!Array.isArray(labels.expect)) throw new Error(`${dir}: expect must be an array of rule ids`)
      if (labels.kind !== 'positive' && labels.kind !== 'evasion' && labels.expect.length > 0) {
        throw new Error(`${dir}: a ${labels.kind} case expects no findings`)
      }
      if ((labels.kind === 'positive' || labels.kind === 'evasion') && labels.expect.length === 0) {
        throw new Error(`${dir}: a ${labels.kind} case names the rule it plants`)
      }
      return { gate, name, dir, labels }
    })
}

function walk(dir) {
  return readdirSync(dir).flatMap((entry) => {
    const path = join(dir, entry)
    return statSync(path).isDirectory() ? walk(path) : [path]
  })
}

function runSwiftgate(args, cwd) {
  const result = spawnSync(swiftgate, [...args, '--json'], { cwd, encoding: 'utf8', maxBuffer: 64 << 20 })
  let report
  try {
    report = JSON.parse(result.stdout)
  } catch {
    throw new Error(`swiftgate ${args.join(' ')} gave no JSON report (exit ${result.status}):\n${result.stderr}`)
  }
  return report
}

function stage(c) {
  const work = mkdtempSync(join(tmpdir(), `corpus-${c.gate}-`))
  if (c.gate === 'prose') {
    for (const file of readdirSync(c.dir).filter((f) => f.endsWith('.md'))) cpSync(join(c.dir, file), join(work, file))
  } else {
    cpSync(join(root, c.labels.base ?? 'examples/SampleApp'), work, { recursive: true })
    if (existsSync(join(c.dir, 'files'))) cpSync(join(c.dir, 'files'), work, { recursive: true })
  }
  // A git root stops swiftgate's config lookup from climbing into whatever holds the temp dir.
  execFileSync('git', ['init', '-q'], { cwd: work })
  return work
}

export function findingsFor(c) {
  if (c.gate === 'prose' && c.labels.paths) {
    return runSwiftgate(['prose', ...c.labels.paths], root).findings
  }
  const work = stage(c)
  try {
    if (c.gate === 'prose') {
      const files = readdirSync(work).filter((f) => f.endsWith('.md'))
      return runSwiftgate(['prose', ...files], work).findings
    }
    if (c.gate === 'lint') {
      const overlay = existsSync(join(c.dir, 'files')) ? walk(join(c.dir, 'files')).map((p) => relative(join(c.dir, 'files'), p)) : []
      const swift = overlay.filter((p) => p.endsWith('.swift'))
      return runSwiftgate(['lint', ...swift], work).findings
    }
    if (c.gate === 'arch') return runSwiftgate(['arch'], work).findings
    throw new Error(`${c.dir}: no swiftgate command for corpus "${c.gate}"`)
  } finally {
    rmSync(work, { recursive: true, force: true })
  }
}

// Scores one case: `found` is the set of rule ids swiftgate reported, after any dropped rules.
export function scoreCase(labels, foundIds) {
  const expect = new Set(labels.expect)
  const found = new Set(foundIds)
  const missed = [...expect].filter((id) => !found.has(id))
  const unexpected = [...found].filter((id) => !expect.has(id))
  return { found: [...found].sort(), missed, unexpected, passed: missed.length === 0 && unexpected.length === 0 }
}

// Per-rule recall on planted cases (positives and evasions apart) and false positives on every
// case that doesn't plant the rule.
export function perRule(results) {
  const rules = new Map()
  const row = (id) => {
    if (!rules.has(id)) rules.set(id, { rule: id, positive: [0, 0], evasion: [0, 0], falsePositives: 0, negatives: 0, falsePositiveCases: [] })
    return rules.get(id)
  }
  for (const r of results) for (const id of [...r.labels.expect, ...r.found]) row(id)
  for (const r of results) {
    for (const [id, stats] of rules) {
      if (r.labels.expect.includes(id)) {
        const bucket = stats[r.labels.kind]
        bucket[1] += 1
        if (r.found.includes(id)) bucket[0] += 1
      } else {
        stats.negatives += 1
        if (r.found.includes(id)) {
          stats.falsePositives += 1
          stats.falsePositiveCases.push(r.name)
        }
      }
    }
  }
  return [...rules.values()].sort((a, b) => a.rule.localeCompare(b.rule))
}

const ratio = ([hit, total]) => (total === 0 ? '–' : `${hit}/${total}`)

export function renderMarkdown(gate, results, rules) {
  const lines = [`## \`${gate}\``, '', `${results.filter((r) => r.passed).length} of ${results.length} cases match their labels.`, '']
  lines.push('| Rule | Recall, positives | Recall, evasions | False positives | Cases |', '|---|---|---|---|---|')
  for (const s of rules) {
    lines.push(`| \`${s.rule}\` | ${ratio(s.positive)} | ${ratio(s.evasion)} | ${s.falsePositives}/${s.negatives} | ${s.falsePositiveCases.join(', ')} |`)
  }
  const failing = results.filter((r) => !r.passed)
  if (failing.length > 0) {
    lines.push('', '| Case | Kind | Missed | Unexpected |', '|---|---|---|---|')
    for (const r of failing) lines.push(`| \`${r.name}\` | ${r.labels.kind} | ${r.missed.join(', ')} | ${r.unexpected.join(', ')} |`)
  }
  return lines.join('\n')
}

function parseArgs(argv) {
  const opts = { corpora: [], drop: new Set(), out: null, check: false }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--drop-rule') opts.drop.add(argv[++i])
    else if (argv[i] === '--out') opts.out = argv[++i]
    else if (argv[i] === '--check') opts.check = true
    else opts.corpora.push(resolve(argv[i]))
  }
  return opts
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  if (opts.corpora.length === 0) {
    console.error('usage: node evals/runner/corpus.mjs <corpus-dir> ... [--out <dir>] [--drop-rule <id>] [--check]')
    process.exit(2)
  }
  const version = execFileSync(swiftgate, ['--version'], { encoding: 'utf8' }).trim()
  const commit = execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim()
  const summary = { swiftgate: version, commit, droppedRules: [...opts.drop], gates: {} }
  const sections = []
  let allPassed = true
  for (const corpus of opts.corpora) {
    const results = loadCases(corpus).map((c) => {
      const started = Date.now()
      const ids = findingsFor(c).map((f) => f.rule).filter((id) => !opts.drop.has(id))
      const score = scoreCase(c.labels, ids)
      return { name: c.name, labels: c.labels, ms: Date.now() - started, ...score }
    })
    const rules = perRule(results)
    // Evasions have no pass bar yet, so they never fail --check.
    allPassed &&= results.every((r) => r.passed || r.labels.kind === 'evasion')
    summary.gates[basename(corpus)] = {
      cases: results.length,
      passed: results.filter((r) => r.passed).length,
      byKind: Object.fromEntries(KINDS.map((k) => [k, results.filter((r) => r.labels.kind === k).length])),
      rules,
      results: results.map(({ labels, ...r }) => ({ ...r, kind: labels.kind, expect: labels.expect })),
    }
    sections.push(renderMarkdown(basename(corpus), results, rules))
  }
  const markdown = sections.join('\n\n')
  console.log(markdown)
  if (opts.out) {
    mkdirSync(opts.out, { recursive: true })
    writeFileSync(join(opts.out, 'corpus.json'), JSON.stringify(summary, null, 2) + '\n')
    writeFileSync(join(opts.out, 'corpus.md'), markdown + '\n')
  }
  if (opts.check && !allPassed) process.exit(1)
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main()
