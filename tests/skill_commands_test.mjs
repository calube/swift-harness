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
  worker: ['--design', '--ledger', '--task-id'],
}
const REQUIRED_RESEARCH_ARGS = ['design:', 'commit:', 'pin:']
// A research launch names the registered workflow, or a copy of its script.
const isResearchCall = call => call.includes('swift-harness-design-research') || call.includes('design-research.js')
// build-task.js throws unless each of these is present (`reviewers` is optional).
const REQUIRED_BUILD_TASK_ARGS = ['task:', 'plan:', 'worktree:', 'branch:', 'writeSet:', 'taskGate:', 'tests:', 'contextPack:', 'model:', 'review:', 'taskProof:']
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
// `sprint finish` read its command, verdict, headCommit and proofBases.
function gateRecord(runID, tier, headCommit, proofBases) {
  const record = {
    command: `check ${tier}`, durationMilliseconds: 1000, findingCount: 0, finishedAt: '2026-01-01T00:00:00Z',
    headCommit, runID, schemaVersion: 1,
    tiers: [{ durationMilliseconds: 500, testCounts: null, tier: 'T0', verdict: 'GREEN' }], verdict: 'GREEN',
  }
  if (proofBases) record.proofBases = proofBases
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
    record(gateRecord('20260101T000001Z-0000bbbb', 'push', head))
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
  const tierAt = (tier, extra = []) => invocations.filter(inv =>
    inv.words[0] === 'check' && inv.words.join(' ').includes(`--tier ${tier}`)
    && extra.every(flag => inv.words.some(w => flagOf(w) === flag))).map(inv => inv.line)
  const gateBefore = (tier, extra, path) => {
    const at = firstLineOf(path.split(' '))
    if (!at) return
    const section = stepNumberAt(text, at)
    if (!tierAt(tier, extra).some(line => line < at && stepNumberAt(text, line) === section)) {
      problems.push(`step ${section} runs \`swiftgate ${path}\` without a \`check --tier ${tier}${extra.map(f => ` ${f}`).join('')}\` before it`)
    }
  }
  gateBefore('push', ['--base'], 'sprint slice')
  gateBefore('ready', ['--base', '--proof-base'], 'sprint finish')
  if (!tierAt('fast').length) problems.push('never runs `swiftgate check --tier fast` as the inner loop')
  if (!invocations.some(inv => inv.words.join(' ').startsWith('sprint status') && inv.words.includes('--json'))) {
    problems.push('never reads `swiftgate sprint status --json`')
  }
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
      'step 2 runs `swiftgate sprint slice` without a `check --tier push --base` before it',
      'step 4 runs `swiftgate sprint finish` without a `check --tier ready --base --proof-base` before it',
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
