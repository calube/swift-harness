// Checks the build and ship skills' telemetry calls: where they ingest agent usage and print the
// build run's summary, that a refused or failed call never stops either skill, and that every
// `events ingest`, `events summary`, `build halt` and `build resume` line they write runs through
// the real binary's argument parser in a temp repository.
// Run: node tests/skill_telemetry_calls_test.mjs
// Regressions caught: a skill dropping its ingest or the summary, a telemetry failure halting a
// build, an opt-out reported as a failure, and a flag or closed value the CLI doesn't have.
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
const TELEMETRY_COMMANDS = ['events ingest', 'events summary', 'build halt', 'build resume']
// The line `events ingest` prints when `[telemetry] enabled = false`; the skills key their quiet
// skip on it.
const OPT_OUT = 'telemetry is off'

const skillFiles = () => Object.fromEntries([BUILD, LOOP, SHIP].map(file => [file, readFileSync(join(root, file), 'utf8')]))

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
  for (const [file, heading] of [[BUILD, '## 3. On each completion'], [SHIP, '## 7. Report']]) {
    const body = section(files[file] ?? '', heading)
    const paragraph = body && paragraphWith(body, 'events ingest')
    if (!paragraph) continue
    if (!new RegExp(`\`${OPT_OUT}\`[^.]*say nothing`).test(paragraph)) problems.push(`${file}: \`${heading}\` never skips an opted-out ingest quietly`)
    if (!/any other non-zero exit[^.]*1 line[^.]*goes on/i.test(paragraph)) problems.push(`${file}: \`${heading}\` never goes on after a failed ingest`)
    if (/\bhalt/i.test(paragraph)) problems.push(`${file}: \`${heading}\` halts on its ingest`)
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
  const ids = { '<session>': 'session-1', '<run>': '20261001T000000Z-abcd1234', '<task>': 'parse-config', '<transcripts>': transcripts }
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

  'a refused or failed ingest never stops the build or the ship report: the opt-out is skipped quietly and any other exit prints 1 line and goes on — catches a telemetry failure halting a build'() {
    const files = skillFiles()
    for (const [file, heading] of [[BUILD, '## 3. On each completion'], [SHIP, '## 7. Report']]) {
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
      '<answer>': ['abandon', 'amend', 'continue', 'retry', 'wait'],
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
