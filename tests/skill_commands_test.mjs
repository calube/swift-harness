// Checks every `swiftgate` / `"$SG"` invocation written in any skills/**/*.md against the real
// binary's `--help` for that subcommand path.
// Run: node tests/skill_commands_test.mjs
// Regressions caught: a skill naming a subcommand or flag the CLI doesn't have (instructions
// drifting from the CLI), an extractor that silently stops finding invocations, and a skill call
// that leaves out a flag or workflow arg the callee requires.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')

// Prefer an explicit binary, then the checkout's debug build (fresh under `swift test`). The
// shim's cold release build would outlast the repository-script timeout, so it isn't a fallback.
function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(root, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : null
}

export function markdownFiles(dir) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory()) out.push(...markdownFiles(path))
    else if (entry.isFile() && entry.name.endsWith('.md')) out.push(path)
  }
  return out.sort()
}

const INVOCATION = /(^|[\s(`'])("\$SG"|\$SG|swiftgate)(?=[ \t]+\S)/g

// The command text after an invocation, up to where a shell or a sentence would end it.
function commandTail(text, isCode) {
  const end = isCode ? /\s(?:\||;|&&|\|\||>|2>)\s|[;]$/ : /[,.;:)](?=\s|$)|\s(?:\||;|&&)\s/
  const match = end.exec(text)
  return (match ? text.slice(0, match.index) : text).trim()
}

const FENCE = /^\s*(```|~~~)/
const LINE_CONTINUATION = /\\\s*$/

// Every invocation in one markdown text: {line, words, isCode}. Code means a fenced block or an
// inline code span; prose mentions only count when their first word is a real subcommand. Inside
// a fenced block, a line ending in `\` joins with the lines after it (a shell continuation), so a
// flag that only appears after the wrap is still checked.
export function extractInvocations(text) {
  const found = []
  let inFence = false
  const lines = text.split('\n')
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index]
    if (FENCE.test(line)) {
      inFence = !inFence
      continue
    }
    const startLine = index + 1
    let logical = line
    if (inFence) {
      while (LINE_CONTINUATION.test(logical) && index + 1 < lines.length && !FENCE.test(lines[index + 1])) {
        logical = logical.replace(LINE_CONTINUATION, ' ') + lines[++index]
      }
    }
    const segments = inFence ? [{ text: logical, isCode: true }] : logical.split('`').map((s, i) => ({ text: s, isCode: i % 2 === 1 }))
    for (const segment of segments) {
      for (const match of segment.text.matchAll(INVOCATION)) {
        const start = match.index + match[0].length
        const tail = commandTail(segment.text.slice(start), segment.isCode)
        const words = tail.split(/\s+/).filter(Boolean)
        if (words.length) found.push({ line: startLine, words, isCode: segment.isCode, fenced: inFence })
      }
    }
  }
  return found
}

function subcommandsIn(help) {
  const at = help.indexOf('\nSUBCOMMANDS:\n')
  if (at < 0) return []
  const names = []
  for (const line of help.slice(at + 14).split('\n')) {
    if (/^\s*See '/.test(line)) break
    const m = /^ {2}([a-z][a-z0-9-]*)(?:\s|$)/.exec(line)
    if (m) names.push(m[1])
  }
  return names
}

function flagsIn(help) {
  const flags = new Set()
  for (const m of help.matchAll(/(?:^|[\s[,])(--[a-z0-9][a-z0-9-]*)/gm)) flags.add(m[1])
  return flags
}

// A flag token as written in a skill: `--x`, `[--x]`, `--x=value`, `[--x <v>]`.
function flagOf(word) {
  const m = /^\[?(--[a-z0-9][a-z0-9-]*)/.exec(word)
  return m ? m[1] : null
}

// Checks each invocation against `help(path)`, which returns the `--help` text for a subcommand
// path. Returns the problems as `file:line: message` strings, plus the resolved invocations.
export function checkInvocations(invocations, help) {
  const problems = []
  const resolved = []
  const rootSubcommands = subcommandsIn(help([]))
  for (const { file, line, words, isCode } of invocations) {
    const where = `${file}:${line}`
    if (!rootSubcommands.includes(words[0])) {
      if (isCode && !flagOf(words[0])) problems.push(`${where}: \`${words[0]}\` is not a swiftgate subcommand`)
      continue
    }
    const path = [words[0]]
    let rest = words.slice(1)
    let subs = subcommandsIn(help(path))
    while (subs.length && rest.length && subs.includes(rest[0])) {
      path.push(rest[0])
      rest = rest.slice(1)
      subs = subcommandsIn(help(path))
    }
    if (subs.length && rest.length && !flagOf(rest[0]) && /^[a-z][a-z0-9-]*$/.test(rest[0])) {
      problems.push(`${where}: \`swiftgate ${path.join(' ')}\` has no subcommand \`${rest[0]}\` (has: ${subs.join(', ')})`)
      continue
    }
    const known = flagsIn(help(path))
    const passthrough = rest.indexOf('--')
    const flags = (passthrough < 0 ? rest : rest.slice(0, passthrough)).map(flagOf).filter(Boolean)
    for (const flag of flags) {
      if (!known.has(flag)) problems.push(`${where}: \`swiftgate ${path.join(' ')}\` has no flag \`${flag}\``)
    }
    resolved.push({ file, line, path: path.join(' '), flags })
  }
  return { problems, resolved }
}

export function scanSkills(skillsDir, help, labelRoot = skillsDir) {
  const invocations = markdownFiles(skillsDir).flatMap(path =>
    extractInvocations(readFileSync(path, 'utf8')).map(inv => ({ ...inv, file: relative(labelRoot, path) })))
  return checkInvocations(invocations, help)
}

// What a call must carry because the callee refuses it otherwise. `context-pack --role
// research-lane` exits 2 without these flags; design-research.js throws without these args.
const REQUIRED_PACK_FLAGS = {
  'research-lane': ['--key', '--design', '--pin'],
  worker: ['--ledger', '--task-id'],
}
// Flag groups a call must carry exactly one of: a worker pack reads its plan's design or its spec page.
const ONE_OF_PACK_FLAGS = {
  worker: [['--design', '--spec-page']],
}
const REQUIRED_RESEARCH_ARGS = ['design:', 'commit:', 'pin:']
// A research launch names the registered workflow, or a copy of its script.
const isResearchCall = call => call.includes('swift-harness-design-research') || call.includes('design-research.js')
// build-task.js throws unless each of these is present (`reviewers` is optional).
const REQUIRED_BUILD_TASK_ARGS = ['task:', 'plan:', 'worktree:', 'branch:', 'writeSet:', 'taskGate:', 'tests:', 'contextPack:', 'model:', 'review:', 'taskProof:', 'planSurface:']
// The PreToolUse guard denies these without the caller's own literal `--session`.
const SESSION_COMMANDS = ['plan claim', 'plan release', 'plan set', 'index set', 'ledger set', 'build start', 'build finish', 'build merge', 'worktree create']

/**
 * Problems with the calls written in `files` ({relative path: markdown}): a fenced `context-pack`
 * command missing a flag its role requires, a design-research Workflow call missing a required
 * arg, and a pre-mortem reading a pack without the claims it cites.
 */
export function requiredCallProblems(files) {
  const problems = []
  for (const [file, text] of Object.entries(files)) {
    for (const { line, words, fenced } of extractInvocations(text)) {
      if (!fenced || words[0] !== 'context-pack') continue
      const role = words[words.indexOf('--role') + 1]
      for (const flag of REQUIRED_PACK_FLAGS[role] ?? []) {
        if (!words.includes(flag)) problems.push(`${file}:${line}: context-pack --role ${role} lacks ${flag}`)
      }
      for (const group of ONE_OF_PACK_FLAGS[role] ?? []) {
        const present = group.filter(flag => words.includes(flag))
        if (present.length !== 1) {
          problems.push(`${file}:${line}: context-pack --role ${role} needs exactly one of ${group.join(', ')}`)
        }
      }
    }
    for (const match of text.matchAll(/Workflow\(\{[\s\S]*?\n\}\)/g)) {
      const call = match[0]
      const line = text.slice(0, match.index).split('\n').length
      if (call.includes('build-task.js')) {
        for (const arg of REQUIRED_BUILD_TASK_ARGS) {
          if (!call.includes(arg)) problems.push(`${file}:${line}: build-task Workflow call lacks ${arg.slice(0, -1)}`)
        }
      }
      if (isResearchCall(call)) {
        for (const arg of REQUIRED_RESEARCH_ARGS) {
          if (!call.includes(arg)) problems.push(`${file}:${line}: design-research Workflow call lacks ${arg.slice(0, -1)}`)
        }
      }
      const preMortem = /reviewer: "pre-mortem", packPath: "([^"]*)"/.exec(call)
      if (preMortem && !preMortem[1].includes('evidence-auditor-pre-mortem')) {
        problems.push(`${file}:${line}: the pre-mortem reads ${JSON.stringify(preMortem[1])}, not its evidence-auditor-pre-mortem pack`)
      }
    }
  }
  return problems
}

function realHelp() {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-'))
  const cache = new Map()
  const help = path => {
    const key = path.join(' ')
    if (!cache.has(key)) {
      cache.set(key, execFileSync(binary, [...path, '--help'], {
        encoding: 'utf8',
        cwd: dir,
        // A coverage-instrumented build writes its profile into the working directory otherwise.
        env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'help-%p.profraw') },
      }))
    }
    return cache.get(key)
  }
  help.cleanup = () => rmSync(dir, { recursive: true, force: true })
  return help
}

function withTempSkill(files, body) {
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-skills-'))
  try {
    for (const [name, text] of Object.entries(files)) {
      mkdirSync(dirname(join(dir, name)), { recursive: true })
      writeFileSync(join(dir, name), text)
    }
    return body(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const help = realHelp()

const designSkillFiles = () =>
  Object.fromEntries(
    markdownFiles(join(root, 'skills/design')).map(path => [relative(root, path), readFileSync(path, 'utf8')]),
  )

const buildSkillFiles = () =>
  Object.fromEntries(
    markdownFiles(join(root, 'skills/build')).map(path => [relative(root, path), readFileSync(path, 'utf8')]),
  )

// The sprint state that follows `step` (`start`, `surface`, `slice <n>`, `finish`), as sprint.json
// holds it, for a 2-slice sprint at `sha`.
function sprintStateAfter(step, sha) {
  const gateRun = '20260101T000000Z-0000abcd'
  const passed = step === 'finish' ? 2 : /^slice (\d+)$/.exec(step)?.[1] ?? 0
  const slices = [1, 2].map(number =>
    number <= Number(passed) ? { number, status: 'passed', gateRun } : { number, status: 'pending' })
  const state = {
    schemaVersion: 1, slug: 'demo', specPage: 'spec-page.md', branch: 'sprint/demo', baseCommit: sha, slices,
    step: step === 'start' ? { name: 'started' } : step === 'surface' ? { name: 'surfaced' }
      : step === 'finish' ? { name: 'finished' } : { name: 'slicing', slice: Number(passed) },
  }
  if (step !== 'start') state.surfaceCommit = sha
  if (step === 'finish') state.finalGateRun = gateRun
  return state
}

// Walks the real state machine through `sprint status --json` in a temp repository: records each
// `next` and `nextCommand`, then writes the state that step leaves, until the machine asks for a
// new `start`. The order comes from the binary, never from this test.
function sprintMachineSteps() {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-sprint-'))
  try {
    const run = (file, args) => execFileSync(file, args, {
      encoding: 'utf8', cwd: dir, env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'status-%p.profraw') },
    })
    run('git', ['init', '-q', '-b', 'main'])
    run('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', 'init'])
    const sha = run('git', ['rev-parse', 'HEAD']).trim()
    const plans = join(dir, '.git/swift-harness/plans')
    mkdirSync(plans, { recursive: true })
    const steps = []
    for (;;) {
      const status = JSON.parse(run(binary, ['sprint', 'status', '--json']))
      if (steps.length && status.next === 'start') return steps
      assert.ok(steps.length < 10, `the machine never returns to start: ${steps.map(s => s.next).join(', ')}`)
      steps.push({ next: status.next, command: status.nextCommand.replace(/^swiftgate\s+/, '').split(/\s+/) })
      writeFileSync(join(plans, 'sprint.json'), JSON.stringify(sprintStateAfter(status.next, sha)))
    }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// A run history line with the keys a captured `check ready` run wrote. `sprint slice` and
// `sprint finish` read its command, verdict, headCommit, proofBases and base.
function gateRecord(runID, tier, headCommit, proofBases, base) {
  const record = {
    command: `check ${tier}`, durationMilliseconds: 1000, findingCount: 0, finishedAt: '2026-01-01T00:00:00Z',
    headCommit, runID, schemaVersion: 1,
    tiers: [{ durationMilliseconds: 500, testCounts: null, tier: 'T0', verdict: 'GREEN' }], verdict: 'GREEN',
  }
  if (proofBases) record.proofBases = proofBases
  if (base) record.base = base
  return JSON.stringify(record) + '\n'
}

// Walks the skill's own path through the real sprint commands in a temp repository: start, the
// surface, an extra stub commit for an API the surface missed, slice 1, then finish with a ready
// run proved at `proofBases(surface, extra)`. Returns finish's JSON report, exit code and whether
// `main` moved to the branch HEAD.
function sprintWalk(proofBases) {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-walk-'))
  const env = {
    ...process.env, LLVM_PROFILE_FILE: join(dir, 'walk-%p.profraw'),
    GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.com', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.com',
  }
  const run = (file, args) => execFileSync(file, args, { encoding: 'utf8', cwd: dir, env })
  const sg = args => {
    try {
      return { code: 0, report: JSON.parse(run(binary, [...args, '--json'])) }
    } catch (error) {
      return { code: error.status, report: JSON.parse(error.stdout) }
    }
  }
  const history = join(dir, '.harness/runs/history.jsonl')
  const record = line => writeFileSync(history, line, { flag: 'a' })
  const source = join(dir, 'Sources/Core/Core.swift')
  const commit = (text, message) => {
    writeFileSync(source, text, { flag: 'a' })
    run('git', ['commit', '-qam', message])
    return run('git', ['rev-parse', 'HEAD']).trim()
  }
  try {
    mkdirSync(join(dir, 'Sources/Core'), { recursive: true })
    mkdirSync(join(dir, '.harness/runs'), { recursive: true })
    writeFileSync(join(dir, '.gitignore'), '.harness/\n')
    writeFileSync(source, 'public func base() -> Int { 1 }\n')
    writeFileSync(join(dir, 'page.md'), '# page\n')
    run('git', ['init', '-q', '-b', 'main'])
    run('git', ['add', '-A'])
    run('git', ['commit', '-qm', 'init'])
    record(gateRecord('20260101T000000Z-0000aaaa', 'push', run('git', ['rev-parse', 'HEAD']).trim()))
    const steps = [sg(['sprint', 'start', 'walk', '--spec-page', 'page.md', '--slices', '1'])]
    run('git', ['switch', '-q', 'sprint/walk'])
    const surface = commit('public func step() -> Int { 0 }\n', 'surface')
    steps.push(sg(['sprint', 'surface', surface]))
    const extra = commit('public func last() -> Int { 0 }\n', 'extra stub')
    steps.push(sg(['surface-check', extra]))
    writeFileSync(source, 'public func base() -> Int { 1 }\npublic func step() -> Int { 2 }\npublic func last() -> Int { 3 }\n')
    run('git', ['commit', '-qam', 'slice 1'])
    const head = run('git', ['rev-parse', 'HEAD']).trim()
    const mainBase = run('git', ['rev-parse', 'main']).trim()
    record(gateRecord('20260101T000003Z-0000dddd', 'push', head, null, mainBase))
    const fromMain = sg(['sprint', 'slice', '1', '--gate', '20260101T000003Z-0000dddd'])
    assert.deepEqual([fromMain.code, fromMain.report.rule], [1, 'sprint.gate-base'], fromMain.report.message)
    record(gateRecord('20260101T000001Z-0000bbbb', 'push', head, null, surface))
    steps.push(sg(['sprint', 'slice', '1', '--gate', '20260101T000001Z-0000bbbb']))
    assert.deepEqual(steps.map(s => [s.report.verdict, s.code]), Array(4).fill(['GREEN', 0]),
      steps.map(s => s.report.message).join('\n'))
    record(gateRecord('20260101T000002Z-0000cccc', 'ready', head, proofBases(surface, extra)))
    const finish = sg(['sprint', 'finish', '--gate', '20260101T000002Z-0000cccc'])
    return { ...finish, mainMoved: run('git', ['rev-parse', 'main']).trim() === head }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// The `## <n>.` step heading a line falls under, or null outside a numbered step.
function stepNumberAt(text, line) {
  let number = null
  for (const [index, row] of text.split('\n').entries()) {
    if (index + 1 > line) break
    const heading = /^## (?:(\d+)\.\s|\S)/.exec(row)
    if (heading) number = heading[1] ? Number(heading[1]) : null
  }
  return number
}

/**
 * Problems with how a sprint skill's `SKILL.md` text follows the machine's `steps`: each step's
 * command, with its flags, under a numbered step heading in the machine's order; a push gate
 * before each slice is recorded and a ready gate proved at the surface before finish; and a
 * `sprint status --json` to read the next step from.
 */
export function sprintSkillProblems(text, steps) {
  const problems = []
  const invocations = extractInvocations(text)
  const firstLineOf = path => invocations.find(inv => inv.words.slice(0, path.length).join(' ') === path.join(' '))?.line
  const order = [...new Set(steps.map(s => s.command.slice(0, 2).join(' ')))]
  let previous = 0
  for (const path of order) {
    const line = firstLineOf(path.split(' '))
    if (!line) { problems.push(`never runs \`swiftgate ${path}\``); continue }
    const step = stepNumberAt(text, line)
    if (step === null) problems.push(`first runs \`swiftgate ${path}\` outside a numbered step (line ${line})`)
    else if (step <= previous) problems.push(`runs \`swiftgate ${path}\` in step ${step}, not after step ${previous}`)
    else previous = step
  }
  for (const { next, command } of steps) {
    const flags = command.filter(word => word.startsWith('--'))
    const path = command.slice(0, 2).join(' ')
    const complete = invocations.some(inv =>
      inv.words.slice(0, 2).join(' ') === path && flags.every(flag => inv.words.some(w => flagOf(w) === flag)))
    if (!complete) problems.push(`never runs \`swiftgate ${path}\` with ${flags.join(' ')} for ${next}`)
  }
  // A flag written `--base <surface>` must be followed by that word; a bare flag by anything.
  const tierAt = (tier, extra = []) => invocations.filter(inv =>
    inv.words[0] === 'check' && inv.words.join(' ').includes(`--tier ${tier}`)
    && extra.every(flag => {
      const [name, value] = flag.split(' ')
      return inv.words.some((w, i) => flagOf(w) === name && (!value || inv.words[i + 1] === value))
    })).map(inv => inv.line)
  const gateBefore = (tier, extra, path) => {
    const at = firstLineOf(path.split(' '))
    if (!at) return
    const section = stepNumberAt(text, at)
    if (!tierAt(tier, extra).some(line => line < at && stepNumberAt(text, line) === section)) {
      problems.push(`step ${section} runs \`swiftgate ${path}\` without a \`check --tier ${tier}${extra.map(f => ` ${f}`).join('')}\` before it`)
    }
  }
  gateBefore('push', ['--base <surface>'], 'sprint slice')
  gateBefore('ready', ['--base', '--proof-base'], 'sprint finish')
  if (!tierAt('fast').length) problems.push('never runs `swiftgate check --tier fast` as the inner loop')
  if (!invocations.some(inv => inv.words.join(' ').startsWith('sprint status') && inv.words.includes('--json'))) {
    problems.push('never reads `swiftgate sprint status --json`')
  }
  return problems
}

/**
 * Problems with where a sprint skill's gates measure from: a push gate after the preflight that
 * isn't `--base <surface>` (`sprint slice` refuses it with `sprint.gate-base`), a ready gate that
 * isn't `--base main` (`finish` needs every line since `main` covered), and a refusal table
 * without the `sprint.gate-base` row.
 */
export function sprintGateBaseProblems(text) {
  const problems = []
  const baseOf = inv => inv.words[inv.words.findIndex(w => flagOf(w) === '--base') + 1]
  for (const inv of extractInvocations(text)) {
    if (inv.words[0] !== 'check') continue
    const tier = inv.words[inv.words.indexOf('--tier') + 1]
    const base = inv.words.some(w => flagOf(w) === '--base') ? baseOf(inv) : null
    if (tier === 'push' && stepNumberAt(text, inv.line) !== 1 && base !== '<surface>') {
      problems.push(`line ${inv.line}: a push gate after the preflight measures from ${base ?? 'no base'}, not <surface>`)
    }
    if (tier === 'ready' && base !== 'main') problems.push(`line ${inv.line}: the ready gate measures from ${base ?? 'no base'}, not main`)
  }
  if (!/^\| `sprint\.gate-base` \|[^\n]*--base <surface>/m.test(text)) problems.push('no `sprint.gate-base` refusal row with its `--base <surface>` fix')
  return problems
}

/**
 * Problems with how a skill's `SKILL.md` text runs doctor before it starts work: under the
 * `heading` section, a `doctor --session` call, and a stop on `doctor.plugin-changed` telling the
 * user to start a fresh session. A running session keeps the prompts it loaded at start, so only
 * a fresh one runs a changed plugin.
 */
function doctorPreflightProblems(text, heading) {
  const padded = `\n${text}`
  const at = padded.indexOf(`\n${heading}\n`)
  if (at < 0) return [`no \`${heading}\` section`]
  const section = padded.slice(at + 1).split(/\n## /)[0]
  const problems = []
  const calls = extractInvocations(section).filter(inv => inv.words[0] === 'doctor')
  if (!calls.some(inv => inv.words.some(w => flagOf(w) === '--session'))) {
    problems.push(`\`${heading}\` never runs \`swiftgate doctor --session\``)
  }
  if (!/`doctor\.plugin-changed`[^]*?\bstop\b[^]*?fresh session/.test(section)) {
    problems.push(`\`${heading}\` never stops on \`doctor.plugin-changed\` for a fresh session`)
  }
  return problems
}

// The `## <n>.` sections of a skill whose headings match `heading`, joined, with the line number
// of each section's first line so invocations keep their place in the whole file.
function numberedSections(text, heading) {
  const lines = text.split('\n')
  const sections = []
  let current = null
  for (const [index, row] of lines.entries()) {
    if (/^## /.test(row)) {
      current = heading.test(row) ? { firstLine: index + 1, lines: [] } : null
      if (current) sections.push(current)
    }
    if (current) current.lines.push(row)
  }
  return sections
}

// The skill's design-free steps: every numbered section whose heading names the spec page or the
// surface. Invocations carry their line in the whole file.
function designFreeInvocations(text) {
  return numberedSections(text, /^## \d+\. (Spec page|Surface)\b/).flatMap(section =>
    extractInvocations(section.lines.join('\n')).map(inv => ({ ...inv, line: inv.line + section.firstLine - 1 })))
}

// The commands a design-free ship records its steps with, in the order a skill first names them.
const SHIP_SPEC_PAGE_COMMANDS = ['plan claim', 'spec-page check', 'plan confirm', 'surface-check', 'check', 'plan surface']

function shipSpecPageCalls(text) {
  const calls = []
  for (const inv of designFreeInvocations(text)) {
    const path = SHIP_SPEC_PAGE_COMMANDS.find(p => inv.words.slice(0, p.split(' ').length).join(' ') === p)
    if (path && !inv.words.includes('--help') && !calls.some(call => call.path === path)) calls.push({ path, words: inv.words, line: inv.line })
  }
  return calls
}

/**
 * Runs `calls` (from `shipSpecPageCalls`) in their order through the real commands in a temp
 * repository, filling each `<placeholder>` from a fixed map, and returns each step's exit code and
 * JSON report until the first non-zero exit. The page is a captured spec page whose every slice
 * quotes its spec; the gate is a GREEN run at the tier the skill names, recorded at the surface
 * commit, so `plan surface` judges that tier. The preset's merge gate is `push`.
 */
function shipSpecPageWalk(calls) {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-ship-'))
  const env = {
    ...process.env, LLVM_PROFILE_FILE: join(dir, 'ship-%p.profraw'),
    GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.com', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.com',
  }
  const run = (file, args) => execFileSync(file, args, { encoding: 'utf8', cwd: dir, env })
  const fixtures = join(root, 'gate/Tests/Fixtures/spec-page')
  const plans = join(dir, '.git/swift-harness/plans')
  const page = join(plans, 'demo/spec-page.md')
  const gateRun = '20260101T000000Z-0000aaaa'
  let surface = null
  const values = () => ({
    '<plan>': 'demo', '<session>': 's1', '<spec-file>': 'spec.md', '<page>': page, '<preset>': 'nodesign',
    '<merge_gate>': 'push', '<by>': 'spec-quotes', '<surface>': surface, '<run id>': gateRun,
  })
  // A placeholder written with a space, such as `<run id>`, splits into 2 words: join them back.
  const joined = words => words.reduce((out, word) =>
    out.length && /<[^>]*$/.test(out.at(-1)) ? [...out.slice(0, -1), `${out.at(-1)} ${word}`] : [...out, word], [])
  const fill = words => joined(words).map(word => word.replace(/<[a-z_ -]+>/g, placeholder => {
    const value = values()[placeholder]
    assert.ok(value, `the walk has no value for ${placeholder} in \`${words.join(' ')}\``)
    return value
  }))
  const writePage = () => {
    if (existsSync(page)) return
    mkdirSync(dirname(page), { recursive: true })
    writeFileSync(page, readFileSync(join(fixtures, 'task-status.page.txt')))
  }
  const commitSurface = () => {
    if (surface) return
    run('git', ['switch', '-q', '-c', 'surface/demo', 'main'])
    writeFileSync(join(dir, 'Sources/Core/Core.swift'), 'public func step() -> Int { 0 }\n', { flag: 'a' })
    run('git', ['commit', '-qam', 'surface'])
    surface = run('git', ['rev-parse', 'HEAD']).trim()
  }
  try {
    mkdirSync(join(dir, 'Sources/Core'), { recursive: true })
    mkdirSync(join(dir, '.harness/runs'), { recursive: true })
    writeFileSync(join(dir, '.gitignore'), '.harness/\n')
    writeFileSync(join(dir, 'Sources/Core/Core.swift'), 'public func base() -> Int { 1 }\n')
    writeFileSync(join(dir, 'spec.md'), readFileSync(join(fixtures, 'task-status.spec.txt')))
    writeFileSync(join(dir, '.swiftgate.toml'), [
      'schema = 1', 'xcode = "26.2"', 'app_scheme = "App"', 'packages = ["Packages/*"]', '',
      '[simulator]', 'device = "iPhone 17"', 'os = "26.2"', '',
      '[build.presets.nodesign]', 'design_tier = "none"', 'max_parallel = 3', 'review = "gate"',
      'task_gate = "fast"', 'merge_gate = "push"', 'worker_model = "tagged"', 'time_budget_min = 0',
      'stop_starts_before_min = 0', 'on_design_conflict = "block"', 'task_proof = "final"', '',
    ].join('\n'))
    run('git', ['init', '-q', '-b', 'main'])
    run('git', ['add', '-A'])
    run('git', ['commit', '-qm', 'init'])
    const steps = []
    for (const { path, words } of calls) {
      if (path === 'spec-page check' || path === 'plan confirm') writePage()
      if (['surface-check', 'check', 'plan surface'].includes(path)) commitSurface()
      if (path === 'check') {
        const [tier] = fill([words[words.indexOf('--tier') + 1]])
        writeFileSync(join(dir, '.harness/runs/history.jsonl'), gateRecord(gateRun, tier, surface), { flag: 'a' })
        steps.push({ path, code: 0, report: null, tier })
        continue
      }
      const args = fill(words)
      if (!args.includes('--json')) args.push('--json')
      let step
      try {
        step = { path, code: 0, report: JSON.parse(run(binary, args)) }
      } catch (error) {
        step = { path, code: error.status, report: JSON.parse(error.stdout) }
      }
      steps.push(step)
      if (step.code !== 0) break
    }
    const planFile = existsSync(join(plans, 'demo/plan.json')) ? JSON.parse(readFileSync(join(plans, 'demo/plan.json'), 'utf8')) : null
    return { steps, planFile, surface, main: run('git', ['rev-parse', 'main']).trim() }
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

// The words of `text` a generic skill must never carry: every preset name the template defines
// except the `default` fallback, and the title of every captured spec page.
function nonGenericWords() {
  const template = readFileSync(join(root, 'templates/swiftgate.toml'), 'utf8')
  const presets = [...template.matchAll(/^\[build\.presets\.([a-z0-9-]+)\]/gm)].map(m => m[1]).filter(name => name !== 'default')
  const fixtures = join(root, 'gate/Tests/Fixtures/spec-page')
  const titles = readdirSync(fixtures).filter(name => name.endsWith('.page.txt'))
    .map(name => /^# (.+)$/m.exec(readFileSync(join(fixtures, name), 'utf8'))[1])
  return [...presets, ...titles]
}

const tests = {
  'ship, build and sprint run doctor with the session id at their preflight and stop on doctor.plugin-changed — catches a session running stale prompts past its preflight'() {
    for (const [skill, heading] of [['ship', '## 1. Preflight'], ['sprint', '## 1. Preflight'], ['build', '## 1. Start']]) {
      const text = readFileSync(join(root, `skills/${skill}/SKILL.md`), 'utf8')
      assert.deepEqual(doctorPreflightProblems(text, heading), [], `the ${skill} skill`)
      const { problems, resolved } = scanSkills(join(root, `skills/${skill}`), help, root)
      assert.deepEqual(problems, [])
      assert.ok(resolved.some(r => r.path === 'doctor' && r.flags.includes('--session')), `the ${skill} skill's doctor --session isn't a real flag`)
    }
    const build = readFileSync(join(root, 'skills/build/SKILL.md'), 'utf8').split('\n## 1. Start\n')[1] ?? ''
    assert.ok(/^\n1\. `"\$SG" doctor --session <session>`/.test(build), 'the build skill does not run doctor as its first start step')
  },

  'a preflight without doctor --session or its stop fails and names both — catches the doctor preflight check passing anything'() {
    const skill = ['## 1. Preflight', '1. `"$SG" doctor`. Any non-zero exit: stop.', '## 2. Next', '`doctor.plugin-changed`: stop; start a fresh session.'].join('\n')
    assert.deepEqual(doctorPreflightProblems(skill, '## 1. Preflight'), [
      '`## 1. Preflight` never runs `swiftgate doctor --session`',
      '`## 1. Preflight` never stops on `doctor.plugin-changed` for a fresh session',
    ])
    assert.deepEqual(doctorPreflightProblems(skill, '## 1. Start'), ['no `## 1. Start` section'])
  },

  'the build skill names every command of its loop with the flags the CLI requires — catches a loop step dropped or a guarded call made without --session'() {
    const files = buildSkillFiles()
    assert.deepEqual(requiredCallProblems(files), [])
    const all = Object.values(files).join('\n')
    const buildCalls = [...all.matchAll(/Workflow\(\{[\s\S]*?\n\}\)/g)].filter(m => m[0].includes('build-task.js'))
    assert.equal(buildCalls.length, 1, 'the build skill launches build-task.js once, with every arg')
    const { problems, resolved } = scanSkills(join(root, 'skills/build'), help, root)
    assert.deepEqual(problems, [])
    const has = (path, flag) => resolved.some(r => r.path === path && (!flag || r.flags.includes(flag)))
    for (const [path, flag] of [
      ['plan claim', '--session'], ['build start', '--preset'], ['build next', '--json'],
      ['worktree create', '--json'], ['context-pack', '--build-run'], ['ledger set', '--json'],
      ['build check-return', '--plan'], ['build check-return', '--fix'], ['build merge', '--undo'],
      ['build merge', '--fix'], ['check', '--tier'], ['worktree remove', '--session'],
      ['worktree remove', '--fix'], ['design-render', '--ledger'], ['build finish', '--session'], ['stats', '--build'],
    ]) assert.ok(has(path, flag), `the build skill never runs \`swiftgate ${path} ${flag}\``)
    const unsessioned = resolved.filter(r => SESSION_COMMANDS.includes(r.path) && !r.flags.includes('--session'))
    assert.deepEqual(unsessioned.map(r => `${r.file}:${r.line} ${r.path}`), [])
  },

  'the build skill packs a spec page plan\'s workers with --spec-page and hands plan.json\'s surfaceCommit to every worker — catches a worker proving at the wrong base or packed from a design the plan lacks'() {
    const files = buildSkillFiles()
    const { resolved } = scanSkills(join(root, 'skills/build'), help, root)
    const packs = resolved.filter(r => r.path === 'context-pack' && r.flags.includes('--build-run'))
    assert.ok(packs.some(r => r.flags.includes('--spec-page') && !r.flags.includes('--design')), 'no worker pack reads a spec page')
    assert.ok(packs.some(r => r.flags.includes('--design') && !r.flags.includes('--spec-page')), 'no worker pack reads a design')
    const all = Object.values(files).join('\n')
    const [launch] = [...all.matchAll(/Workflow\(\{[\s\S]*?\n\}\)/g)].filter(m => m[0].includes('build-task.js')).map(m => m[0])
    assert.match(launch ?? '', /planSurface: "<plan\.json's surfaceCommit, or null>"/)
    const skill = files['skills/build/SKILL.md']
    assert.match(skill, /`surfaceCommit`/, 'the build skill never reads the plan surface from plan.json')
    assert.match(skill, /"source": "specPage"/, 'the build skill never tells a spec page plan from a design plan')

    assert.deepEqual(requiredCallProblems({
      'x.md': [
        '```bash',
        '"$SG" context-pack --role worker --ledger l.json --task-id t --build-run r',
        '"$SG" context-pack --role worker --design d.md --spec-page p.md --ledger l.json --task-id t',
        '"$SG" context-pack --role worker --spec-page p.md --ledger l.json --task-id t',
        '```',
        '```',
        'Workflow({',
        '  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/build-task.js",',
        '  args: { task: "t", plan: "p", worktree: "w", branch: "b", writeSet: [], taskGate: "fast", tests: [],',
        '    contextPack: "c", model: "opus", review: "gate", taskProof: "final" }',
        '})',
        '```',
      ].join('\n'),
    }), [
      'x.md:2: context-pack --role worker needs exactly one of --design, --spec-page',
      'x.md:3: context-pack --role worker needs exactly one of --design, --spec-page',
      'x.md:7: build-task Workflow call lacks planSurface',
    ])
  },

  'the ship skill runs its preflight, hands the preset to each step and reports the build — catches a preflight check or the build hand-off dropped'() {
    const shipDir = join(root, 'skills/ship')
    assert.ok(existsSync(shipDir), 'no ship skill')
    const files = Object.fromEntries(
      markdownFiles(shipDir).map(path => [relative(root, path), readFileSync(path, 'utf8')]),
    )
    assert.deepEqual(requiredCallProblems(files), [])
    const { problems, resolved } = scanSkills(shipDir, help, root)
    assert.deepEqual(problems, [])
    const has = (path, flag) => resolved.some(r => r.path === path && (!flag || r.flags.includes(flag)))
    for (const [path, flag] of [
      ['doctor', null], ['worktree warm-check', '--json'], ['design-render', '--ledger'],
      ['stats', '--build'], ['stats', '--plan'],
    ]) assert.ok(has(path, flag), `the ship skill never runs \`swiftgate ${path}${flag ? ` ${flag}` : ''}\``)
    const all = Object.values(files).join('\n')
    for (const step of [
      /\/swift-harness:design <spec-file> --tier <design_tier>/,
      /\/swift-harness:plan <plan>/,
      /\/swift-harness:build <plan> --preset <preset>/,
    ]) assert.ok(step.test(all), `the ship skill never runs ${step.source}`)
    const unsessioned = resolved.filter(r => SESSION_COMMANDS.includes(r.path) && !r.flags.includes('--session'))
    assert.deepEqual(unsessioned.map(r => `${r.file}:${r.line} ${r.path}`), [])
  },

  'the sprint skill runs each sprint step in the state machine\'s order with a gate before each record — catches a step dropped, reordered, run without its flags or recorded without its gate'() {
    const sprintDir = join(root, 'skills/sprint')
    assert.ok(existsSync(join(sprintDir, 'SKILL.md')), 'no sprint skill')
    const { problems } = scanSkills(sprintDir, help, root)
    assert.deepEqual(problems, [])
    const steps = sprintMachineSteps()
    assert.deepEqual(steps.map(s => s.next.replace(/\d+$/, 'n')), ['start', 'surface', 'slice n', 'slice n', 'finish'])
    assert.deepEqual(sprintSkillProblems(readFileSync(join(sprintDir, 'SKILL.md'), 'utf8'), steps), [])
    const text = markdownFiles(sprintDir).map(path => readFileSync(path, 'utf8')).join('\n')
    assert.ok(/AskUserQuestion/.test(text), 'the sprint skill never confirms a spec page with AskUserQuestion')
    assert.ok(!/sprint\.json/.test(text) || /never edit[^.]*sprint\.json/i.test(text), 'the sprint skill names sprint.json without forbidding edits to it')
  },

  'sprint finish accepts the skill\'s extra stub commit as a second proof base and still needs the surface — catches the skill\'s missed-API path ending in a refusal'() {
    const accepted = sprintWalk((surface, extra) => [surface, extra])
    assert.deepEqual([accepted.code, accepted.report.verdict, accepted.mainMoved], [0, 'GREEN', true], accepted.report.message)
    const refused = sprintWalk((_, extra) => [extra])
    assert.deepEqual([refused.code, refused.report.rule, refused.mainMoved], [1, 'sprint.gate-proof-base', false], refused.report.message)
    const finishStep = readFileSync(join(root, 'skills/sprint/SKILL.md'), 'utf8').split('\n## 6. Finish\n')[1] ?? ''
    assert.ok(/--proof-base <surface>`[^]*--proof-base <sha>`[^]*oldest first/.test(finishStep), 'the finish step never adds an extra stub commit as a later proof base')
  },

  'the sprint skill measures slice gates from the surface and the ready gate from main — catches a slice gate example that sprint slice refuses'() {
    assert.deepEqual(sprintGateBaseProblems(readFileSync(join(root, 'skills/sprint/SKILL.md'), 'utf8')), [])
    const wrong = [
      '| `sprint.gate-red` | fix |',
      '```bash', '"$SG" check --tier push --base main > out', '```',
      '## 1. Preflight', '`"$SG" check --tier push --base main`',
      '## 5. Slices', '`"$SG" check --tier push --base <surface>`',
      '## 6. Finish', '`"$SG" check --tier ready --base <surface> --proof-base <surface>`',
    ].join('\n')
    assert.deepEqual(sprintGateBaseProblems(wrong), [
      'line 3: a push gate after the preflight measures from main, not <surface>',
      'line 10: the ready gate measures from <surface>, not main',
      'no `sprint.gate-base` refusal row with its `--base <surface>` fix',
    ])
  },

  'the sprint skill halts on a slice that declares a target the surface lacks — catches the refusal row dropped or turned into a fix the machine can\'t record'() {
    const text = readFileSync(join(root, 'skills/sprint/SKILL.md'), 'utf8')
    assert.ok(/^\| `sprint\.target-outside-surface` \| halt\b/m.test(text), 'no `sprint.target-outside-surface` refusal row that halts')
  },

  'the sprint skill states what its rehearsals hit — catches a lesson line dropped from the page'() {
    // A lesson may wrap across lines, so the patterns read the page with its whitespace collapsed.
    const prose = readFileSync(join(root, 'skills/sprint/SKILL.md'), 'utf8').replace(/\s+/g, ' ')
    const { problems, resolved } = scanSkills(join(root, 'skills/sprint'), help, root)
    assert.deepEqual(problems, [])
    for (const [path, flag] of [['surface-check', null], ['sprint status', '--json'], ['check', '--proof-base']]) {
      assert.ok(resolved.some(r => r.path === path && (!flag || r.flags.includes(flag))), `the sprint skill never runs \`swiftgate ${path}${flag ? ` ${flag}` : ''}\``)
    }
    for (const [lesson, pattern] of [
      ['a spec file may sit outside the repository', /`<spec-file>` \|[^|]*outside the repository/],
      ['a new dependency accessor stubs as `.init()` and a no-op setter', /`get \{ \.init\(\) \}` and `set \{\}`[^.]*`self\[Key\.self\]`/],
      ['a surface may add to an existing Package.swift', /add dependencies, products and targets to an existing `Package\.swift`/],
      ['a surface-check finding takes no swiftgate:allow', /`surface-check` finding takes no `swiftgate:allow`/],
      ['the ready gate runs in the foreground', /ready gate in the foreground[^.]*never in the background/],
      ['the main session writes the spec page itself', /plan-state guard lets a main session write a sprint page and never a subagent/],
    ]) assert.ok(pattern.test(prose), `the sprint skill never says ${lesson}`)
  },

  'a sprint skill out of the machine\'s order or missing a gate fails and names it — catches the sprint order check passing anything'() {
    const steps = [
      { next: 'start', command: ['sprint', 'start', '<slug>', '--spec-page', '<path>', '--slices', '<n>'] },
      { next: 'surface', command: ['sprint', 'surface', '<surface sha>'] },
      { next: 'slice 1', command: ['sprint', 'slice', '1', '--gate', '<push run id>'] },
      { next: 'finish', command: ['sprint', 'finish', '--gate', '<ready run id>'] },
    ]
    const skill = [
      '## Driving', '`swiftgate sprint status --json`.',
      '## 1. Start', '`swiftgate sprint start <slug> --spec-page <page> --slices <n> --json`',
      '## 2. Slices', '`swiftgate check --tier fast --base main`', '`swiftgate sprint slice <n> --json`',
      '## 3. Surface', '`swiftgate sprint surface <sha> --json`',
      '## 4. Finish', '`swiftgate check --tier ready --base main`', '`swiftgate sprint finish --gate <id> --json`',
    ].join('\n')
    assert.deepEqual(sprintSkillProblems(skill, steps), [
      'runs `swiftgate sprint slice` in step 2, not after step 3',
      'never runs `swiftgate sprint slice` with --gate for slice 1',
      'step 2 runs `swiftgate sprint slice` without a `check --tier push --base <surface>` before it',
      'step 4 runs `swiftgate sprint finish` without a `check --tier ready --base --proof-base` before it',
    ])
    const fromMain = [
      '## Driving', '`swiftgate sprint status --json`.',
      '## 1. Start', '`swiftgate sprint start <slug> --spec-page <page> --slices <n> --json`',
      '## 2. Surface', '`swiftgate sprint surface <sha> --json`',
      '## 3. Slices', '`swiftgate check --tier fast --base main`', '`swiftgate check --tier push --base main`',
      '`swiftgate sprint slice <n> --gate <id> --json`',
      '## 4. Finish', '`swiftgate check --tier ready --base main --proof-base <surface>`', '`swiftgate sprint finish --gate <id> --json`',
    ].join('\n')
    assert.deepEqual(sprintSkillProblems(fromMain, steps), [
      'step 3 runs `swiftgate sprint slice` without a `check --tier push --base <surface>` before it',
    ])
  },

  'the design skill\'s sketch path lints, synthesizes no review and records the approval — catches the sketch branch skipping a gate'() {
    const { problems, resolved } = scanSkills(join(root, 'skills/design'), help, root)
    assert.deepEqual(problems, [])
    const text = readFileSync(join(root, 'skills/design/references/review-publish-amend.md'), 'utf8')
    const at = text.indexOf('\n## Sketch\n')
    assert.ok(at >= 0, 'no Sketch section in review-publish-amend.md')
    const sketch = text.slice(at + 1).split(/\n## /)[0]
    const firstLine = text.slice(0, at + 1).split('\n').length
    const lastLine = firstLine + sketch.split('\n').length - 1
    const inSketch = (path, flag) => resolved.some(r =>
      r.file === 'skills/design/references/review-publish-amend.md' && r.line >= firstLine && r.line <= lastLine
      && r.path === path && (!flag || r.flags.includes(flag)))
    for (const [path, flag] of [
      ['design-lint', null], ['docs-lint', '--json'], ['review-synth', '--tier'], ['design-diff', '--json'],
      ['evidence check', '--design'], ['index set', '--session'], ['plan release', '--session'],
    ]) assert.ok(inSketch(path, flag), `the sketch path never runs \`swiftgate ${path}${flag ? ` ${flag}` : ''}\``)
    assert.ok(/--tier sketch/.test(sketch), 'the sketch review-synth is not run at --tier sketch')
    assert.ok(/AskUserQuestion/.test(sketch) && /"kind":"answer"/.test(sketch), 'the sketch approval is not an answer claim')
    assert.ok(/tier: sketch/.test(sketch), 'the sketch doc does not record tier: sketch')
  },

  'the design skill passes every flag and arg its callees require — catches a skill call a stricter CLI or workflow now refuses'() {
    const files = designSkillFiles()
    assert.deepEqual(requiredCallProblems(files), [])
    const all = Object.values(files).join('\n')
    assert.ok(/context-pack --role evidence-auditor --key pre-mortem/.test(all), 'no pre-mortem pack is built')
    const workflowCalls = [...all.matchAll(/Workflow\(\{[\s\S]*?\n\}\)/g)].map(m => m[0])
    const researchCalls = workflowCalls.filter(isResearchCall)
    assert.ok(researchCalls.length >= 2, `only ${researchCalls.length} design-research calls found`)
    // The Workflow tool refuses a scriptPath outside the session's working directory, and the
    // plugin root is outside every consumer repository.
    assert.deepEqual(workflowCalls.filter(call => /scriptPath:\s*"\$\{CLAUDE_PLUGIN_ROOT\}/.test(call)), [])
    assert.ok(workflowCalls.some(call => call.includes('name: "swift-harness-design-review"')), 'the review workflow is not launched by name')
  },

  'the design skill records every workflow launch with design-telemetry and every flag it needs — catches a launch whose cost is written by hand or not at all'() {
    const files = designSkillFiles()
    const { problems, resolved } = scanSkills(join(root, 'skills/design'), help, root)
    assert.deepEqual(problems, [])
    const calls = Object.entries(files).flatMap(([file, text]) =>
      extractInvocations(text).filter(inv => inv.fenced && inv.words[0] === 'design-telemetry').map(inv => ({ file, ...inv })))
    const required = ['--run', '--run-id', '--phase', '--workflow-result', '--started-at', '--session']
    for (const call of calls) {
      for (const flag of required) assert.ok(call.words.includes(flag), `${call.file}:${call.line} design-telemetry lacks ${flag}`)
      assert.ok(call.words[call.words.indexOf('--run-id') + 1] === '<design-run>', `${call.file}:${call.line} --run-id is not <design-run>`)
    }
    const phases = new Set(calls.map(call => call.words[call.words.indexOf('--phase') + 1]))
    for (const phase of ['research', 'review', 'revise', 'amend']) {
      assert.ok(phases.has(phase), `no design-telemetry call records --phase ${phase}`)
    }
    const all = Object.values(files).join('\n')
    const launches = [...all.matchAll(/Workflow\(\{[\s\S]*?\n\}\)/g)].length
    assert.ok(calls.length >= launches, `${launches} workflow launches but ${calls.length} design-telemetry calls`)
    assert.ok(/date -u \+%Y-%m-%dT%H:%M:%SZ/.test(all), 'the skill never notes a launch time for --started-at')
    assert.ok(!/Log 1 line per lane when the Workflow result/.test(all), 'the phase log still asks for hand-written workflow lines')
  },

  'a call missing a required flag or arg fails and names it — catches the required-call check passing anything'() {
    const problems = requiredCallProblems({
      'x.md': [
        '```bash',
        '"$SG" context-pack --role research-lane --key codebase --pin abc1234 \\',
        '  --brief b.md',
        '```',
        'Prose mentions `"$SG" context-pack --role research-lane` without flags.',
        '```',
        'Workflow({',
        '  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/design-research.js",',
        '  args: { design: "d.md", lanes: [{ name: "codebase", packPath: "p", pin: "abc1234" }] }',
        '})',
        '```',
        '```',
        'Workflow({',
        '  args: { packs: [{ reviewer: "pre-mortem", packPath: "<absolute path of the challenger pack>" }] }',
        '})',
        '```',
      ].join('\n'),
    })
    assert.deepEqual(problems, [
      'x.md:2: context-pack --role research-lane lacks --design',
      'x.md:7: design-research Workflow call lacks commit',
      'x.md:13: the pre-mortem reads "<absolute path of the challenger pack>", not its evidence-auditor-pre-mortem pack',
    ])
  },

  'every swiftgate subcommand and flag any skill names exists in the real CLI — catches skill instructions drifting from the CLI'() {
    const { problems, resolved } = scanSkills(join(root, 'skills'), help, root)
    assert.deepEqual(problems, [])
    // The extractor must keep finding what's there: a regex that stops matching would pass above.
    assert.ok(resolved.length >= 40, `only ${resolved.length} invocations found`)
    const has = (file, path, flag) => resolved.some(r => r.file === file && r.path === path && (!flag || r.flags.includes(flag)))
    assert.ok(has('skills/review/SKILL.md', 'review-synth', '--run-directory'))
    assert.ok(has('skills/design/SKILL.md', 'plan claim', '--session'), 'design skill claims the plan with --session')
    // The design session hands the plan on: it releases its claim, re-scopes with plan set, and
    // stores captures before the lanes run.
    const design = 'skills/design/references/review-publish-amend.md'
    const frame = 'skills/design/references/frame-research-verify.md'
    assert.ok(has(design, 'plan release', '--session'), 'the design skill never releases its claim')
    assert.ok(has(frame, 'plan set', '--tier'), 'a re-scope never updates plan.json')
    assert.ok(has(frame, 'evidence capture', '--design'), 'no capture step before the lanes')
    assert.ok(has('skills/design/references/frame-research-verify.md', 'evidence check', '--json'), 'reference files are scanned')
    assert.ok(has('skills/design/references/frame-research-verify.md', 'context-pack', '--role'))
    // `index set` refuses any session that doesn't hold the plan's lock, so every call names one.
    const indexSets = resolved.filter(r => r.path === 'index set')
    assert.ok(indexSets.length >= 10, `only ${indexSets.length} index set calls found`)
    assert.deepEqual(indexSets.filter(r => !r.flags.includes('--session')).map(r => `${r.file}:${r.line}`), [])
  },

  'a skill naming a nonexistent flag fails and names it — catches a checker that passes anything'() {
    withTempSkill({
      'demo/SKILL.md': [
        'Run `"$SG" prose <file> --json` first.',
        '```',
        '"$SG" evidence check --design <doc> --no-such-flag',
        '```',
      ].join('\n'),
    }, dir => {
      const { problems, resolved } = scanSkills(dir, help)
      assert.deepEqual(problems, ['demo/SKILL.md:3: `swiftgate evidence check` has no flag `--no-such-flag`'])
      assert.deepEqual(resolved.map(r => [r.line, r.path]), [[1, 'prose'], [3, 'evidence check']])
    })
  },

  'unknown subcommands fail at the root and nested — catches `--help` exiting 0 with the parent help'() {
    withTempSkill({
      'demo/references/deep.md': [
        'Then `swiftgate evidence verify --design <doc>`.',
        'Then `swiftgate frobnicate`.',
        'The `swiftgate` module graph and swiftgate is the gate, in prose.',
      ].join('\n'),
    }, dir => {
      const { problems } = scanSkills(dir, help)
      assert.deepEqual(problems, [
        'demo/references/deep.md:1: `swiftgate evidence` has no subcommand `verify` (has: check, capture, find, cache)',
        'demo/references/deep.md:2: `frobnicate` is not a swiftgate subcommand',
      ])
    })
  },

  'a bad flag on a backslash-continued line fails and names it — catches a checker that only reads a wrapped command\'s first line'() {
    withTempSkill({
      'demo/SKILL.md': [
        'Run this:',
        '```',
        '"$SG" evidence check --design <doc> \\',
        '  --no-such-flag',
        '```',
      ].join('\n'),
    }, dir => {
      const { problems, resolved } = scanSkills(dir, help)
      assert.deepEqual(problems, ['demo/SKILL.md:3: `swiftgate evidence check` has no flag `--no-such-flag`'])
      assert.deepEqual(resolved.map(r => [r.line, r.path, r.flags]), [[3, 'evidence check', ['--design', '--no-such-flag']]])
    })
  },

  'bracketed, valued and passthrough forms parse to the right flags — catches false positives from placeholders and `-- <cmd>`'() {
    const found = extractInvocations([
      '`swiftgate plan claim <plan> --session <id> [--tier quick|standard|deep] [--json]`',
      '```bash',
      '"$SG" evidence capture --design docs/a/designs/b.md -- swift package --version | tee out',
      '```',
      'Run swiftgate check --tier push, then stop.',
      'SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate" and `// swiftgate:allow rule — reason`',
    ].join('\n'))
    assert.deepEqual(found.map(f => [f.line, f.words, f.isCode]), [
      [1, ['plan', 'claim', '<plan>', '--session', '<id>', '[--tier', 'quick|standard|deep]', '[--json]'], true],
      [3, ['evidence', 'capture', '--design', 'docs/a/designs/b.md', '--', 'swift', 'package', '--version'], true],
      [5, ['check', '--tier', 'push'], false],
    ])
    const { problems, resolved } = checkInvocations(found.map(f => ({ ...f, file: 'x.md' })), help)
    assert.deepEqual(problems, [])
    assert.deepEqual(resolved.map(r => [r.path, r.flags]), [
      ['plan claim', ['--session', '--tier', '--json']],
      ['evidence capture', ['--design']],
      ['check', ['--tier']],
    ])
  },

  'the ship skill\'s design-free steps run the spec page and surface commands in an order the real commands accept — catches a step dropped, reordered or written with a flag its command refuses'() {
    const text = readFileSync(join(root, 'skills/ship/SKILL.md'), 'utf8')
    const { problems } = scanSkills(join(root, 'skills/ship'), help, root)
    assert.deepEqual(problems, [])
    const calls = shipSpecPageCalls(text)
    assert.deepEqual(calls.map(call => call.path), SHIP_SPEC_PAGE_COMMANDS)
    const walk = shipSpecPageWalk(calls)
    assert.deepEqual(walk.steps.map(step => [step.path, step.code]), calls.map(call => [call.path, 0]),
      walk.steps.map(step => step.report?.message).filter(Boolean).join('\n'))
    assert.deepEqual([walk.planFile.surfaceCommit, walk.main, walk.planFile.approval.by], [walk.surface, walk.surface, 'spec-quotes'])
    assert.equal(walk.steps.find(step => step.path === 'check').tier, 'fast', 'the surface gate runs at another tier than fast')
    // The numbered step that runs `skill`, as [its first line, its body].
    const stepRunning = (heading, skill) => {
      const [section] = numberedSections(text, heading)
      assert.ok(section?.lines.join('\n').includes(skill), `no step runs ${skill}`)
      return section.firstLine
    }
    const planStep = stepRunning(/^## \d+\. Plan\b/, '/swift-harness:plan <plan>')
    assert.ok(planStep > calls.at(-1).line, 'the plan step does not follow the surface')
    assert.ok(stepRunning(/^## \d+\. Build\b/, '/swift-harness:build <plan> --preset <preset>') > planStep, 'the build step does not follow the plan')
    const [design] = numberedSections(text, /^## \d+\. Design\b/)
    assert.ok(/`none`/.test(design?.lines.join('\n') ?? ''), 'the design step never says a `none` preset skips it')
  },

  'the real commands refuse the ship skill\'s design-free steps out of order — catches an order check that passes anything'() {
    const calls = shipSpecPageCalls(readFileSync(join(root, 'skills/ship/SKILL.md'), 'utf8'))
    const move = (path, to) => {
      const rest = calls.filter(call => call.path !== path)
      rest.splice(to < 0 ? rest.length : to, 0, calls.find(call => call.path === path))
      return rest
    }
    const unconfirmed = shipSpecPageWalk(move('plan confirm', -1)).steps.at(-1)
    assert.deepEqual([unconfirmed.path, unconfirmed.code, unconfirmed.report.rule], ['plan surface', 1, 'plan-surface.not-confirmed'])
    const unclaimed = shipSpecPageWalk(move('plan claim', -1)).steps.at(-1)
    assert.deepEqual([unclaimed.path, unclaimed.code, unclaimed.report.status], ['plan confirm', 1, 'not-held'])
    assert.deepEqual(shipSpecPageCalls(['## 3. Spec page', '`"$SG" spec-page check <page> --spec <spec-file>`', '## 4. Plan', '`"$SG" plan claim <plan>`'].join('\n'))
      .map(call => call.path), ['spec-page check'])
  },

  'the ship skill asks about the spec page only when spec-page check says required, resumes from plan.json and runs every step its preset runs — catches a confirm asked every time or never, or a resume that restarts the page'() {
    const text = readFileSync(join(root, 'skills/ship/SKILL.md'), 'utf8')
    const prose = text.replace(/\s+/g, ' ')
    const [page] = numberedSections(text, /^## \d+\. Spec page\b/)
    const pageText = (page?.lines ?? []).join(' ').replace(/\s+/g, ' ')
    assert.match(pageText, /`confirm` is `required`[^.]*AskUserQuestion/, 'the page step never asks only on `confirm: required`')
    assert.match(pageText, /`skippable`[^.]*`--by spec-quotes`/, 'a skippable page is not confirmed by its spec quotes')
    assert.match(prose, /Never skip a step the preset runs/)
    assert.doesNotMatch(prose, /Never skip a step or/)
    const resume = (text.split('\n## Stop and resume\n')[1] ?? '').split('\n## ')[0].replace(/\s+/g, ' ')
    for (const [what, pattern] of [
      ['an unconfirmed page', /no `approval`/], ['a surface not yet recorded', /no `surfaceCommit`/],
      ['a recorded surface', /`surfaceCommit`[^|]*\|[^|]*\/swift-harness:plan <plan>/],
    ]) assert.match(resume, pattern, `the resume list never covers ${what}`)
  },

  'the plan skill plans a confirmed spec page without the design approval or evidence steps and packs its decomposer with --spec-page — catches a spec page plan halted on a missing designSha'() {
    const text = readFileSync(join(root, 'skills/plan/SKILL.md'), 'utf8')
    const { problems, resolved } = scanSkills(join(root, 'skills/plan'), help, root)
    assert.deepEqual(problems, [])
    const at = text.indexOf('\n### A spec-page plan\n')
    assert.ok(at >= 0, 'no `### A spec-page plan` section')
    const section = text.slice(at + 1).split(/\n#{2,3} /)[0]
    const commands = extractInvocations(section).map(inv => inv.words.slice(0, 2).join(' '))
    assert.deepEqual(commands.filter(c => /^(design-diff|evidence check)/.test(c)), [])
    for (const word of ['`approval`', '`surfaceCommit`', 'plan confirm', 'plan surface']) {
      assert.ok(section.includes(word), `the spec-page section never names ${word}`)
    }
    const step3 = (text.split('\n## 3. ')[1] ?? '').split('\n## ')[0].replace(/\s+/g, ' ')
    assert.match(step3, /spec-page plan skips this step/)
    const decomposer = extractInvocations(text).filter(inv => inv.fenced && inv.words[0] === 'context-pack' && inv.words.includes('decomposer'))
    assert.ok(decomposer.some(inv => inv.words.includes('--spec-page') && !inv.words.includes('--design')), 'no decomposer pack reads a spec page')
    assert.ok(decomposer.some(inv => inv.words.includes('--design') && !inv.words.includes('--spec-page')), 'no decomposer pack reads a design')
    assert.ok(resolved.some(r => r.path === 'plan set' && r.flags.includes('--resume') && r.flags.includes('--session')), 'a spec-page plan\'s resume note is written by hand')
    assert.match(text.replace(/\s+/g, ' '), /`plan-lint\.spec-page-moved`[^.]*halt/, 'a moved page goes to the decomposer\'s fix round')
  },

  'the plan, build and ship skills report the ledger page\'s path and go on when the session has no Artifact tool — catches a headless run halted by a view'() {
    for (const [skill, slug] of [['plan', 'slug'], ['build', 'slug'], ['ship', 'plan']]) {
      const prose = readFileSync(join(root, `skills/${skill}/SKILL.md`), 'utf8').replace(/\s+/g, ' ')
      const fallback = new RegExp(`no Artifact tool, don't publish: report the rendered page's path, \`\\.harness/design-render/<${slug}>-ledger\\.html\`, in its place and go on\\. The page is a view, never a gate\\.`)
      assert.match(prose, fallback, `the ${skill} skill`)
    }
    const report = (readFileSync(join(root, 'skills/plan/SKILL.md'), 'utf8').split('\n## Report\n')[1] ?? '').replace(/\s+/g, ' ')
    assert.match(report, /^ ?End with the Artifact link, or the page's path when this session has no Artifact tool,/)
  },

  'the ship and plan skills\' design-free text names no preset or captured page — catches a skill tuned to one preset or app'() {
    const words = nonGenericWords()
    assert.ok(words.length >= 4 && words.includes('interview'), `the generic check reads only ${words.join(', ')}`)
    const ship = readFileSync(join(root, 'skills/ship/SKILL.md'), 'utf8')
    const plan = readFileSync(join(root, 'skills/plan/SKILL.md'), 'utf8')
    const texts = {
      'ship design-free steps': numberedSections(ship, /^## \d+\. (Spec page|Surface)\b/).map(s => s.lines.join('\n')).join('\n'),
      'plan spec-page section': (plan.split('\n### A spec-page plan\n')[1] ?? '').split(/\n#{2,3} /)[0],
    }
    for (const [name, body] of Object.entries(texts)) {
      assert.ok(body.length > 200, `no ${name} to check`)
      const found = words.filter(word => new RegExp(`\\b${word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i').test(body))
      assert.deepEqual(found, [], `the ${name} name ${found.join(', ')}`)
    }
  },
}

let failed = 0
try {
  for (const [name, test] of Object.entries(tests)) {
    try {
      await test()
      console.log(`ok   ${name}`)
    } catch (error) {
      failed++
      console.log(`FAIL ${name}\n     ${String(error.message).split('\n').join('\n     ')}`)
    }
  }
} finally {
  help.cleanup()
}
if (failed) {
  console.log(`${failed} failed`)
  process.exit(1)
}
