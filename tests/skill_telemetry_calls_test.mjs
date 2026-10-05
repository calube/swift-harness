// Checks the build, run and ship skills' telemetry calls: where they ingest agent usage and print
// the build run's summary, where they open and close phase spans, that a refused or failed call
// never stops a skill, and that every `events ingest`, `events summary`, `build halt`,
// `build resume` and `events span` line they write runs through the real binary in a temp
// repository.
// Run: node tests/skill_telemetry_calls_test.mjs
// Regressions caught: a skill dropping its ingest, the summary or a phase span, a span left open
// by a halt, a telemetry failure halting a build, an opt-out reported as a failure, and a flag or
// closed value the CLI doesn't have.
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { extractInvocations, swiftgateBinary } from './skill_commands_test.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const BUILD = 'skills/build/SKILL.md'
const LOOP = 'skills/build/references/event-loop.md'
const SHIP = 'skills/ship/SKILL.md'
const RUN = 'skills/run/SKILL.md'
const TELEMETRY_COMMANDS = ['events ingest', 'events summary', 'build halt', 'build resume']
// The line `events ingest` prints when `[telemetry] enabled = false`; the skills key their quiet
// skip on it.
const OPT_OUT = 'telemetry is off'

// The sections whose ingest must skip an opt-out quietly and go on after any other failure.
const INGEST_SECTIONS = [[BUILD, '## 3. On each completion'], [LOOP, '## Conflict or red main'], [SHIP, '## 7. Report']]

const skillFiles = () => Object.fromEntries([BUILD, LOOP, SHIP].map(file => [file, readFileSync(join(root, file), 'utf8')]))
const spanFiles = () => Object.fromEntries([BUILD, LOOP, RUN, SHIP].map(file => [file, readFileSync(join(root, file), 'utf8')]))

// The body of the `## ` section whose heading line starts with `heading`, up to the next `## `.
function section(text, heading) {
  const at = text.indexOf(`\n${heading}`)
  if (at < 0) return null
  const body = text.slice(at + 1)
  const next = body.indexOf('\n## ', 1)
  return next < 0 ? body : body.slice(0, next)
}

// The paragraph or list item of `text` holding `needle`, whitespace folded.
function paragraphWith(text, needle) {
  const block = text.split(/\n\s*\n|\n(?=\d+\. )/).find(block => block.includes(needle))
  return block ? block.replace(/\s+/g, ' ') : null
}

// The calls each skill section must make, by the flags (and their values) each carries.
const REQUIRED = [
  {
    file: BUILD, heading: '## 3. On each completion', path: 'events ingest',
    flags: { '--session': '<session>', '--workflow-transcripts': '<transcripts>', '--role': 'build-worker', '--task': '<task>', '--build-run': '<run>' },
  },
  // The merge fixer is the build session's own subagent; its own ingest tags it build-fixer with
  // the task it fixes, which the session's ingest can't tell.
  {
    file: LOOP, heading: '## Conflict or red main', path: 'events ingest',
    flags: { '--session': '<session>', '--agent-id': '<agent>', '--role': 'build-fixer', '--task': '<task>', '--build-run': '<run>' },
  },
  { file: SHIP, heading: '## 7. Report', path: 'events ingest', flags: { '--session': '<session>', '--role': 'orchestrator', '--build-run': '<run>' } },
  { file: SHIP, heading: '## 7. Report', path: 'events summary', flags: { '--build-run': '<run>' } },
]

/**
 * Problems with the telemetry calls in `files` ({relative path: markdown}): a required call
 * missing from its section or missing a flag, a summary printed before its ingest, a
 * `<transcripts>` the names table doesn't define, and an ingest whose paragraph doesn't skip an
 * opt-out quietly, doesn't carry on after any other failure, or halts.
 */
export function telemetryCallProblems(files) {
  const problems = []
  for (const { file, heading, path, flags } of REQUIRED) {
    const body = section(files[file] ?? '', heading)
    if (body === null) {
      problems.push(`${file}: no \`${heading}\` section`)
      continue
    }
    const calls = extractInvocations(body).filter(inv => inv.words.slice(0, 2).join(' ') === path)
    const complete = calls.find(inv => Object.entries(flags).every(([flag, value]) => inv.words[inv.words.indexOf(flag) + 1]?.replace(/\]$/, '') === value))
    if (!complete) {
      const want = Object.entries(flags).map(([flag, value]) => `${flag} ${value}`).join(' ')
      problems.push(`${file}: \`${heading}\` never runs \`swiftgate ${path} ${want}\``)
    }
  }
  const report = section(files[SHIP] ?? '', '## 7. Report') ?? ''
  const ingestAt = report.indexOf('events ingest')
  const summaryAt = report.indexOf('events summary')
  if (ingestAt >= 0 && summaryAt >= 0 && summaryAt < ingestAt) problems.push(`${SHIP}: the summary prints before this session's usage is ingested`)
  if (!/^\| `<transcripts>` \|[^\n]*Workflow tool printed/m.test(files[BUILD] ?? '')) {
    problems.push(`${BUILD}: no \`<transcripts>\` row naming the transcript directory the Workflow tool printed`)
  }
  for (const [file, heading] of INGEST_SECTIONS) {
    const body = section(files[file] ?? '', heading)
    const paragraph = body && paragraphWith(body, 'events ingest')
    if (!paragraph) continue
    if (!new RegExp(`\`${OPT_OUT}\`[^.]*say nothing`).test(paragraph)) problems.push(`${file}: \`${heading}\` never skips an opted-out ingest quietly`)
    if (!/any other non-zero exit[^.]*1 line[^.]*goes on/i.test(paragraph)) problems.push(`${file}: \`${heading}\` never goes on after a failed ingest`)
    if (/\bhalt/i.test(paragraph)) problems.push(`${file}: \`${heading}\` halts on its ingest`)
  }
  return problems
}

// The run skill's ingests: its validation worker is an Agent-tool subagent of the run's session,
// tagged alone when it returns, and the run's last ingest, at the report, reads every message the
// session and its agents wrote after their own completion ingests.
const RUN_REQUIRED = [
  { heading: '## 7. Import and build', path: 'events ingest', flags: { '--session': '<session>', '--agent-id': '<agent>', '--role': 'qa', '--task': '<task>', '--build-run': '<run>' } },
  { heading: '## 9. Report', path: 'events ingest', flags: { '--session': '<session>', '--role': 'orchestrator', '--build-run': '<run>' } },
  { heading: '## 9. Report', path: 'events summary', flags: { '--build-run': '<run>' } },
]

/**
 * Problems with the run skill `text`'s usage calls: a required call missing or missing a flag, a
 * report ingest after `run report` or after the summary, and an ingest whose paragraph doesn't
 * skip an opt-out quietly, doesn't carry on after any other failure, or halts.
 */
export function runTelemetryProblems(text) {
  const problems = []
  for (const { heading, path, flags } of RUN_REQUIRED) {
    const body = section(text, heading)
    if (body === null) {
      problems.push(`${RUN}: no \`${heading}\` section`)
      continue
    }
    const calls = extractInvocations(body).filter(inv => inv.words.slice(0, 2).join(' ') === path)
    if (!calls.some(inv => Object.entries(flags).every(([flag, value]) => inv.words[inv.words.indexOf(flag) + 1] === value))) {
      const want = Object.entries(flags).map(([flag, value]) => `${flag} ${value}`).join(' ')
      problems.push(`${RUN}: \`${heading}\` never runs \`swiftgate ${path} ${want}\``)
    }
    const paragraph = path === 'events ingest' && paragraphWith(body, `--role ${flags['--role']}`)
    if (!paragraph) continue
    if (!new RegExp(`\`${OPT_OUT}\`[^.]*say nothing`).test(paragraph)) problems.push(`${RUN}: \`${heading}\` never skips an opted-out ingest quietly`)
    if (!/any other non-zero exit[^.]*1 line[^.]*goes on/i.test(paragraph)) problems.push(`${RUN}: \`${heading}\` never goes on after a failed ingest`)
    if (/\bhalt/i.test(paragraph)) problems.push(`${RUN}: \`${heading}\` halts on its ingest`)
  }
  const report = section(text, '## 9. Report') ?? ''
  const at = needle => report.indexOf(needle)
  if (at('events ingest') >= 0 && at('run report') >= 0 && at('run report') < at('events ingest')) {
    problems.push(`${RUN}: the report is written before the session's usage is ingested`)
  }
  if (at('events ingest') >= 0 && at('events summary') >= 0 && at('events summary') < at('events ingest')) {
    problems.push(`${RUN}: the summary prints before the session's usage is ingested`)
  }
  return problems
}

// The closed values a column of the event loop's halt tables lists: every backticked word in the
// column headed `--reason` or `--answer`.
export function tableValues(loop, column) {
  const values = new Set()
  let at = -1
  for (const line of loop.split('\n')) {
    if (!line.startsWith('|')) {
      at = -1
      continue
    }
    const cells = line.split('|').slice(1, -1).map(cell => cell.trim())
    if (at < 0) {
      at = cells.indexOf(`\`${column}\``)
      continue
    }
    for (const match of (cells[at] ?? '').matchAll(/`([a-z-]+)`/g)) values.add(match[1])
  }
  return [...values].sort()
}

// Every telemetry invocation in `files`, as argument lists ready to run: placeholders become ids,
// `<reason>` and `<answer>` become each value the tables list, and an optional `[--flag <v>]`
// loses its brackets. Returns {runs: [{where, args}], problems}.
export function telemetryRuns(files, values, transcripts) {
  const ids = { '<session>': 'session-1', '<run>': '20261001T000000Z-abcd1234', '<task>': 'parse-config', '<transcripts>': transcripts, '<agent>': 'a705c5b0d3c2b4f5b' }
  const runs = []
  const problems = []
  for (const [file, text] of Object.entries(files)) {
    for (const { line, words } of extractInvocations(text)) {
      if (!TELEMETRY_COMMANDS.includes(words.slice(0, 2).join(' '))) continue
      const base = words.map(word => word.replace(/^\[|\]$/g, '')).map(word => ids[word] ?? word)
      const where = `${file}:${line}`
      const slot = base.findIndex(word => word === '<reason>' || word === '<answer>')
      const expanded = slot < 0 ? [base] : (values[base[slot]] ?? []).map(value => base.with(slot, value))
      if (expanded.length === 0) problems.push(`${where}: no table lists the values of ${base[slot]}`)
      for (const args of expanded) {
        const left = args.filter(word => /^<.*>$/.test(word))
        if (left.length) problems.push(`${where}: \`${args.join(' ')}\` keeps ${left.join(', ')}`)
        else runs.push({ where, args })
      }
    }
  }
  return { runs, problems }
}

// The phase spans each skill opens, with the build run id each names and any other flag values
// it must carry. The run skill's phases before `build start` have no build run yet, so they name
// the plan slug. The merge fixer's span sits inside its task, as the workflow's fix pass does.
const SPANS = [
  [RUN, 'spec-read', '<slug>'], [RUN, 'explore', '<slug>'],
  [RUN, 'plan', '<slug>'], [RUN, 'contract', '<slug>'], [RUN, 'final', '<run>'],
  [BUILD, 'final', '<run>'], [SHIP, 'ship', '<run>'],
  [LOOP, 'fix', '<run>', { '--task': '<task>', '--role': 'build-worker' }],
]
// Phases the run viewer derives from their own events in a skill's run; a span call would draw
// them twice.
const DERIVED = [[RUN, 'discover']]
// A block that hands control away from the skill's own steps: a span still open there never ends.
const LEAVES = /\bhalts?\b|\bends the run\b/i
const isSpan = (inv, edge) => inv.words[0] === 'events' && inv.words[1] === 'span' && (!edge || inv.words[2] === edge)
const flagValue = (words, flag) => (words.includes(flag) ? words[words.indexOf(flag) + 1] : undefined)

// The `## ` sections of `text`: {heading, line (1-based), body}.
function sections(text) {
  const lines = text.split('\n')
  const out = []
  for (const [index, row] of lines.entries()) {
    if (row.startsWith('## ')) out.push({ heading: row, line: index + 1, rows: [] })
    else out.at(-1)?.rows.push(row)
  }
  return out.map(s => ({ heading: s.heading, line: s.line, body: s.rows.join('\n') }))
}

// The paragraphs and numbered items of `body`: {first, last, text}, lines counted from 1.
function blocks(body) {
  const out = []
  let current = null
  for (const [index, row] of body.split('\n').entries()) {
    if (!row.trim() || /^\s*\d+\. /.test(row)) {
      if (current) out.push(current)
      current = null
      if (!row.trim()) continue
    }
    current ??= { first: index + 1, last: index + 1, text: '' }
    current.last = index + 1
    current.text += `${row}\n`
  }
  if (current) out.push(current)
  return out
}

/**
 * Problems with the phase spans in `files` ({relative path: markdown}): a phase a skill never
 * opens or opens under the wrong build run id, a section that opens a span and never ends it `ok`,
 * a halt or run end after a span call that doesn't end the span in the same block, and a skill
 * that never says an empty span id is skipped and a failed span call goes on.
 */
export function spanCallProblems(files) {
  const problems = []
  for (const [file, phase, run, flags = {}] of SPANS) {
    const start = extractInvocations(files[file] ?? '').find(inv => isSpan(inv, 'start') && flagValue(inv.words, '--phase') === phase)
    if (!start) problems.push(`${file}: never starts the \`${phase}\` span`)
    else if (flagValue(start.words, '--build-run') !== run) problems.push(`${file}: the \`${phase}\` span names --build-run ${flagValue(start.words, '--build-run')}, not ${run}`)
    else {
      for (const [flag, value] of Object.entries(flags)) {
        if (flagValue(start.words, flag) !== value) problems.push(`${file}: the \`${phase}\` span names ${flag} ${flagValue(start.words, flag)}, not ${value}`)
      }
    }
  }
  for (const [file, phase] of DERIVED) {
    if (extractInvocations(files[file] ?? '').some(inv => isSpan(inv, 'start') && flagValue(inv.words, '--phase') === phase)) {
      problems.push(`${file}: starts the \`${phase}\` span the viewer derives from its own events`)
    }
  }
  for (const [file, text] of Object.entries(files)) {
    for (const { heading, body } of sections(text)) {
      const calls = extractInvocations(body).filter(inv => isSpan(inv))
      if (!calls.length) continue
      for (const start of calls.filter(inv => isSpan(inv, 'start'))) {
        const ended = calls.some(inv => isSpan(inv, 'end') && inv.line > start.line && flagValue(inv.words, '--outcome') === 'ok')
        if (!ended) problems.push(`${file}: \`${heading}\` never ends the \`${flagValue(start.words, '--phase')}\` span ok`)
      }
      // A halt after the span already ended ok, such as a report listing halts, leaves nothing open.
      const closed = Math.max(...calls.filter(inv => isSpan(inv, 'end') && flagValue(inv.words, '--outcome') === 'ok').map(inv => inv.line))
      const until = Number.isFinite(closed) ? closed : Infinity
      for (const block of blocks(body)) {
        if (block.last < calls[0].line || block.first > until || !LEAVES.test(block.text)) continue
        if (!extractInvocations(block.text).some(inv => isSpan(inv, 'end'))) {
          problems.push(`${file}: \`${heading}\` leaves its span open at "${block.text.trim().replace(/\s+/g, ' ').slice(0, 60)}"`)
        }
      }
    }
  }
  for (const file of [BUILD, RUN, SHIP]) {
    const rule = blocks(files[file] ?? '').map(b => b.text.replace(/\s+/g, ' '))
      .some(text => text.includes('events span') && /Empty output[^.]*skip its end.*any other non-zero exit[^.]*1 line[^.]*goes on/i.test(text))
    if (!rule) problems.push(`${file}: never says an empty span id skips its end and a failed span call goes on`)
  }
  return problems
}

// Every `events span` line in `files` as runnable pairs: each start alone, and each end after a
// fresh start of the nearest start above it in its file (the event loop's ends close the build
// skill's `final` span). Returns {starts, pairs, problems}.
export function spanRuns(files) {
  const ids = { '<slug>': 'demo-plan', '<run>': '20261001T000000Z-abcd1234', '<task>': 'parse-config' }
  const fill = words => words.map(word => word.replace(/^\[|\]$/g, '')).map(word => ids[word] ?? word)
  const starts = []
  const pairs = []
  const problems = []
  const buildFinal = extractInvocations(files[BUILD] ?? '').find(inv => isSpan(inv, 'start') && flagValue(inv.words, '--phase') === 'final')
  for (const [file, text] of Object.entries(files)) {
    let open = file === LOOP ? buildFinal : null
    // A start closes only within its own section; past it, the event loop's ends close `final`.
    const headingAt = line => text.split('\n').slice(0, line).filter(row => row.startsWith('## ')).length
    for (const inv of extractInvocations(text).filter(inv => isSpan(inv))) {
      const where = `${file}:${inv.line}`
      const args = fill(inv.words)
      if (file === LOOP && open && open !== buildFinal && headingAt(open.line) !== headingAt(inv.line)) open = buildFinal
      if (inv.words[2] === 'start') {
        open = inv
        starts.push({ where, args })
      } else if (!open) problems.push(`${where}: ends a span no start above it opens`)
      else pairs.push({ where, start: fill(open.words), end: args })
      const left = args.filter(word => /^<.*>$/.test(word) && word !== '<span>')
      if (left.length) problems.push(`${where}: \`${args.join(' ')}\` keeps ${left.join(', ')}`)
      if (inv.words[2] === 'end' && inv.words[3] !== '<span>') problems.push(`${where}: ends ${inv.words[3]}, not the kept <span>`)
    }
  }
  return { starts, pairs, problems }
}

// A temp git repository with a project config, `[telemetry] enabled = <enabled>` appended.
function withRepository(enabled, body) {
  const dir = mkdtempSync(join(tmpdir(), 'skill-telemetry-'))
  try {
    mkdirSync(join(dir, 'Probe'))
    writeFileSync(join(dir, 'Probe/Package.swift'), '// swift-tools-version: 6.2\n')
    writeFileSync(join(dir, '.swiftgate.toml'), [
      'schema = 1', 'xcode = "26.2"', 'app_scheme = "Probe"', 'packages = ["Probe"]', '',
      '[simulator]', 'device = "iPhone 17"', 'os = "26.2"', '', '[telemetry]', `enabled = ${enabled}`, '',
    ].join('\n'))
    const git = spawnSync('git', ['init', '-q'], { cwd: dir, encoding: 'utf8' })
    assert.equal(git.status, 0, git.stderr)
    return body(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function run(dir, args) {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const result = spawnSync(binary, args, {
    cwd: dir,
    encoding: 'utf8',
    // A coverage-instrumented build writes its profile into the working directory otherwise.
    env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'run-%p.profraw') },
  })
  return { status: result.status, out: `${result.stdout}${result.stderr}` }
}

const tests = {
  'the build skill ingests each completed task\'s worker transcripts, and ship\'s report ingests its session before printing the build run\'s summary — catches a skill that drops an ingest or the summary'() {
    assert.deepEqual(telemetryCallProblems(skillFiles()), [])
  },

  'the run skill tags its validation worker alone when it returns and ingests the session again at the report, before the build run\'s summary, each ingest going on after any failure — catches a run whose cost misses every message after the last task completion'() {
    const text = readFileSync(join(root, RUN), 'utf8')
    assert.deepEqual(runTelemetryProblems(text), [])
    const { runs, problems } = telemetryRuns({ [RUN]: ['## 7. Import and build', '## 9. Report'].map(heading => section(text, heading)).join('\n') }, {}, '')
    assert.deepEqual(problems.filter(problem => problem.includes('`events ')), [])
    const usage = runs.filter(({ args }) => args[0] === 'events')
    assert.equal(usage.length, 3, usage.map(r => r.args.join(' ')).join('\n'))
    const results = withRepository(false, dir => usage.map(({ where, args }) => ({ where, args, ...run(dir, args) })))
    const wrong = results.filter(r => r.args[1] === 'ingest' ? r.status !== 2 || !r.out.includes(OPT_OUT) : r.status !== 0)
    assert.deepEqual(wrong.map(r => `${r.where}: exit ${r.status} for \`${r.args.join(' ')}\`: ${r.out.trim()}`), [])
  },

  'the run telemetry check names a missing validation ingest, a report ingest after the report and the summary, and a halting ingest — catches a check that passes anything'() {
    const text = [
      '# Run', '', '## 7. Import and build', '',
      'When it returns, ingest: `"$SG" events ingest --session <session> --role qa --task <task> --build-run <run>`. A failure halts the run.', '',
      '## 9. Report', '',
      '`"$SG" run report <slug>` prints the report, then `"$SG" events summary --build-run <run>`.', '',
      'Then `"$SG" events ingest --session <session> --role orchestrator --build-run <run>`; an exit 2 that says `telemetry is off` means say nothing, and any other non-zero exit prints 1 line and the report goes on.', '',
    ].join('\n')
    assert.deepEqual(runTelemetryProblems(text), [
      `${RUN}: \`## 7. Import and build\` never runs \`swiftgate events ingest --session <session> --agent-id <agent> --role qa --task <task> --build-run <run>\``,
      `${RUN}: \`## 7. Import and build\` never skips an opted-out ingest quietly`,
      `${RUN}: \`## 7. Import and build\` never goes on after a failed ingest`,
      `${RUN}: \`## 7. Import and build\` halts on its ingest`,
      `${RUN}: the report is written before the session's usage is ingested`,
      `${RUN}: the summary prints before the session's usage is ingested`,
    ])
    assert.deepEqual(runTelemetryProblems('# Run\n'), [
      `${RUN}: no \`## 7. Import and build\` section`,
      `${RUN}: no \`## 9. Report\` section`,
      `${RUN}: no \`## 9. Report\` section`,
    ])
  },

  'a refused or failed ingest never stops the build or the ship report: the opt-out is skipped quietly and any other exit prints 1 line and goes on — catches a telemetry failure halting a build'() {
    const files = skillFiles()
    for (const [file, heading] of INGEST_SECTIONS) {
      const paragraph = paragraphWith(section(files[file], heading) ?? '', 'events ingest')
      assert.ok(paragraph, `${file}: no ingest in \`${heading}\``)
      assert.doesNotMatch(paragraph, /\bhalt/i, `${file}: ${paragraph}`)
      assert.match(paragraph, /any other non-zero exit[^.]*1 line[^.]*goes on/i, `${file}: ${paragraph}`)
      assert.match(paragraph, /`telemetry is off`[^.]*say nothing/, `${file}: ${paragraph}`)
    }
    // The skills tell an opt-out from a failure by the line the real binary prints.
    const ingest = ['events', 'ingest', '--session', 'session-1', '--role', 'orchestrator']
    const off = withRepository(false, dir => run(dir, ingest))
    assert.equal(off.status, 2, off.out)
    assert.ok(off.out.includes(OPT_OUT), `an opted-out ingest prints no \`${OPT_OUT}\`: ${off.out}`)
    const failed = withRepository(true, dir => run(dir, ingest))
    assert.equal(failed.status, 2, failed.out)
    assert.ok(!failed.out.includes(OPT_OUT), `a failed ingest reads as an opt-out: ${failed.out}`)
  },

  'every events ingest, events summary, build halt and build resume line in the build and ship skills parses with the real argument parser, for every reason and answer the halt tables list — catches a flag or closed value the CLI doesn\'t have'() {
    const files = skillFiles()
    const values = { '<reason>': tableValues(files[LOOP], '--reason'), '<answer>': tableValues(files[LOOP], '--answer') }
    assert.deepEqual(values, {
      '<reason>': ['amend', 'budget', 'gate-red', 'merge-conflict', 'permission', 'question', 'stall'],
      '<answer>': ['abandon', 'amend', 'continue', 'merge', 'retry', 'wait'],
    })
    const results = withRepository(false, dir => {
      const { runs, problems } = telemetryRuns(files, values, dir)
      assert.deepEqual(problems, [])
      return runs.map(({ where, args }) => ({ where, args, ...run(dir, args) }))
    })
    const byCommand = command => results.filter(r => r.args.slice(0, 2).join(' ') === command)
    assert.ok(byCommand('events ingest').length >= 2, `only ${byCommand('events ingest').length} ingest lines`)
    assert.ok(byCommand('events summary').length >= 1, 'no summary line')
    assert.ok(byCommand('build halt').length >= 7 && byCommand('build resume').length >= 5, 'the halt lines lost their reasons or answers')
    // With telemetry off, ingest refuses with its opt-out line and the rest record nothing and pass.
    const wrong = results.filter(r => r.args[1] === 'ingest' ? r.status !== 2 || !r.out.includes(OPT_OUT) : r.status !== 0)
    assert.deepEqual(wrong.map(r => `${r.where}: exit ${r.status} for \`${r.args.join(' ')}\`: ${r.out.trim()}`), [])
  },

  'the build loop times the merge fixer in a fix span inside its task and ingests the fixer alone as that task\'s build-fixer, ending the span before any halt — catches a merge fixer drawn nowhere and billed to the orchestrator'() {
    const loop = section(skillFiles()[LOOP], '## Conflict or red main')
    assert.ok(loop, 'no `## Conflict or red main` section')
    const calls = extractInvocations(loop)
    const start = calls.find(inv => isSpan(inv, 'start') && flagValue(inv.words, '--phase') === 'fix')
    assert.ok(start, 'the fixer runs with no fix span')
    assert.deepEqual(['--build-run', '--task', '--role'].map(flag => flagValue(start.words, flag)), ['<run>', '<task>', 'build-worker'])
    const launch = loop.split('\n').findIndex(row => /Launch `swift-harness:build-fixer`/.test(row)) + 1
    assert.ok(launch > 0, 'no fixer launch')
    assert.ok(start.line < launch, 'the fix span opens after the fixer runs')
    const ends = calls.filter(inv => isSpan(inv, 'end') && inv.line > launch)
    assert.deepEqual(ends.map(inv => flagValue(inv.words, '--outcome')).sort(), ['ok', 'red'], 'the fix span is not ended by the fixer\'s outcome')
    const ingest = calls.find(inv => inv.words.slice(0, 2).join(' ') === 'events ingest')
    assert.ok(ingest && ingest.line > launch, 'the fixer\'s usage is never ingested after it returns')
    assert.equal(flagValue(ingest.words, '--workflow-transcripts'), undefined, 'the fixer ingest tags a whole transcript directory')
    assert.match(loop, /`agentId: <agent>`|agentId[^\n]*<agent>/, 'the loop never says where <agent> comes from')
  },

  'the run skill times spec-read, explore, plan, contract and final and leaves discover to its own events, the build skill final and ship its report, each ended ok and on every halt — catches a phase never timed or a span left open by a halt'() {
    assert.deepEqual(spanCallProblems(spanFiles()), [])
  },

  'every events span line in the build, run and ship skills runs through the real binary: a start prints a 16-hex id, its end records, and with telemetry off a start prints nothing and exits 0 — catches a flag, phase or outcome the CLI lacks, or a skill reading an opt-out as a failure'() {
    const { starts, pairs, problems } = spanRuns(spanFiles())
    assert.deepEqual(problems, [])
    assert.ok(starts.length >= 7 && pairs.length >= 10, `only ${starts.length} starts and ${pairs.length} ends`)
    withRepository(true, dir => {
      const failures = []
      for (const { where, args } of starts) {
        const result = spawnSync(swiftgateBinary(), args, { cwd: dir, encoding: 'utf8', env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'run-%p.profraw') } })
        if (result.status !== 0 || !/^[0-9a-f]{16}\n?$/.test(result.stdout)) failures.push(`${where}: exit ${result.status}, stdout ${JSON.stringify(result.stdout)} ${result.stderr.trim()}`)
      }
      for (const { where, start, end } of pairs) {
        const id = spawnSync(swiftgateBinary(), start, { cwd: dir, encoding: 'utf8', env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'run-%p.profraw') } }).stdout.trim()
        const result = run(dir, end.map(word => word === '<span>' ? id : word))
        if (result.status !== 0) failures.push(`${where}: exit ${result.status} for \`${end.join(' ')}\`: ${result.out.trim()}`)
      }
      assert.deepEqual(failures, [])
      const ended = run(dir, ['events', 'list', '--kind', 'span.end']).out.trim().split('\n').filter(Boolean)
      assert.equal(ended.length, pairs.length, 'the store holds a span.end for each end line')
      // A refused span call prints 1 line, which the skills report and go past.
      const refused = run(dir, ['events', 'span', 'end', '0123456789abcdef', '--outcome', 'ok'])
      assert.equal(refused.status, 1, refused.out)
      assert.equal(refused.out.trim().split('\n').length, 1, refused.out)
    })
    withRepository(false, dir => {
      for (const { where, args } of starts) {
        const result = spawnSync(swiftgateBinary(), args, { cwd: dir, encoding: 'utf8', env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'run-%p.profraw') } })
        assert.deepEqual([result.status, result.stdout], [0, ''], `${where}: ${result.stderr}`)
      }
    })
  },

  'the span call check names a missing phase, a derived phase opened by hand, a wrong build run, a span never ended ok, a halt that leaves it open and a missing failure rule — catches a check that passes anything'() {
    const build = [
      '# Build', '', '## 4. Finish', '',
      '1. `"$SG" events span start --phase final --build-run <slug>`. Not GREEN: halt.', '',
      '2. `"$SG" events span end <span> --outcome halted`.', '',
    ].join('\n')
    const run = [
      '# Run', '', 'Span calls: `events span start` prints the id. Empty output: skip its end. Any other non-zero exit prints 1 line and the step goes on.', '',
      '## 1. Read', '', '`"$SG" events span start --phase spec-read --build-run <slug>`', '',
      'A red read ends the run.', '', '`"$SG" events span end <span> --outcome ok`', '',
      '## 2. Areas', '', '`"$SG" events span start --phase discover --build-run <slug>`', '',
      '`"$SG" events span end <span> --outcome ok`', '',
    ].join('\n')
    const loop = [
      '## Conflict or red main', '', '`"$SG" events span start --phase fix --build-run <run> --role orchestrator`', '',
      '`"$SG" events span end <span> --outcome ok`', '',
    ].join('\n')
    assert.deepEqual(spanCallProblems({ [BUILD]: build, [LOOP]: loop, [RUN]: run, [SHIP]: '# Ship\n' }), [
      `${RUN}: never starts the \`explore\` span`,
      `${RUN}: never starts the \`plan\` span`,
      `${RUN}: never starts the \`contract\` span`,
      `${RUN}: never starts the \`final\` span`,
      `${BUILD}: the \`final\` span names --build-run <slug>, not <run>`,
      `${SHIP}: never starts the \`ship\` span`,
      `${LOOP}: the \`fix\` span names --task undefined, not <task>`,
      `${LOOP}: the \`fix\` span names --role orchestrator, not build-worker`,
      `${RUN}: starts the \`discover\` span the viewer derives from its own events`,
      `${BUILD}: \`## 4. Finish\` never ends the \`final\` span ok`,
      `${BUILD}: \`## 4. Finish\` leaves its span open at "1. \`"$SG" events span start --phase final --build-run <slug>"`,
      `${RUN}: \`## 1. Read\` leaves its span open at "A red read ends the run."`,
      `${BUILD}: never says an empty span id skips its end and a failed span call goes on`,
      `${SHIP}: never says an empty span id skips its end and a failed span call goes on`,
    ])
    const { pairs, problems } = spanRuns({ [LOOP]: '`"$SG" events span end <span> --outcome halted`\n', [SHIP]: '`"$SG" events span end <id> --outcome ok`\n' })
    assert.deepEqual(problems, [`${LOOP}:1: ends a span no start above it opens`, `${SHIP}:1: ends a span no start above it opens`, `${SHIP}:1: \`events span end <id> --outcome ok\` keeps <id>`, `${SHIP}:1: ends <id>, not the kept <span>`])
    assert.equal(pairs.length, 0)
  },

  'the telemetry call check names a dropped ingest, a missing flag, a summary before its ingest, a missing names row, a halting ingest and an unquiet opt-out — catches a check that passes anything'() {
    const build = [
      '| `<run>` | the run |', '',
      '## 3. On each completion', '',
      'Record usage: `"$SG" events ingest --session <session> --role build-worker --task <task> --build-run <run>`. A failure halts that task.', '',
      '## 4. Finish', '',
    ].join('\n')
    const ship = [
      '# Ship', '', '## 7. Report', '',
      '1. `"$SG" events summary --build-run <run>`', '',
      '2. `"$SG" events ingest --session <session> --role orchestrator`. Any other non-zero exit prints 1 line and the report goes on.', '',
    ].join('\n')
    assert.deepEqual(telemetryCallProblems({ [BUILD]: build, [SHIP]: ship }), [
      `${BUILD}: \`## 3. On each completion\` never runs \`swiftgate events ingest --session <session> --workflow-transcripts <transcripts> --role build-worker --task <task> --build-run <run>\``,
      `${LOOP}: no \`## Conflict or red main\` section`,
      `${SHIP}: \`## 7. Report\` never runs \`swiftgate events ingest --session <session> --role orchestrator --build-run <run>\``,
      `${SHIP}: the summary prints before this session's usage is ingested`,
      `${BUILD}: no \`<transcripts>\` row naming the transcript directory the Workflow tool printed`,
      `${BUILD}: \`## 3. On each completion\` never skips an opted-out ingest quietly`,
      `${BUILD}: \`## 3. On each completion\` never goes on after a failed ingest`,
      `${BUILD}: \`## 3. On each completion\` halts on its ingest`,
      `${SHIP}: \`## 7. Report\` never skips an opted-out ingest quietly`,
    ])
    assert.deepEqual(telemetryCallProblems({ [SHIP]: '# Ship\n' }), [
      `${BUILD}: no \`## 3. On each completion\` section`,
      `${LOOP}: no \`## Conflict or red main\` section`,
      `${SHIP}: no \`## 7. Report\` section`,
      `${SHIP}: no \`## 7. Report\` section`,
      `${BUILD}: no \`<transcripts>\` row naming the transcript directory the Workflow tool printed`,
    ])
  },

  'the telemetry runs expand each reason and answer, strip optional brackets and name a placeholder left unfilled — catches a walk that runs nothing'() {
    const text = ['```', '"$SG" build halt --run <run> [--task <task>] --reason <reason>', '"$SG" events summary --since <window>', '```'].join('\n')
    const { runs, problems } = telemetryRuns({ 'x.md': text }, { '<reason>': ['stall', 'budget'] }, '/t')
    assert.deepEqual(runs.map(r => r.args.join(' ')), [
      'build halt --run 20261001T000000Z-abcd1234 --task parse-config --reason stall',
      'build halt --run 20261001T000000Z-abcd1234 --task parse-config --reason budget',
    ])
    assert.deepEqual(problems, ['x.md:3: `events summary --since <window>` keeps <window>'])
    assert.deepEqual(tableValues('| a | `--answer` |\n|---|---|\n| x | `retry`, or `wait` |\n\n| `--answer` |\n', '--answer'), ['retry', 'wait'])
  },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
  try {
    await test()
    console.log(`ok   ${name}`)
  } catch (error) {
    failed++
    console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
  }
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
