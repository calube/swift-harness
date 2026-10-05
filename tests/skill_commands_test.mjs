// Checks every `swiftgate` / `"$SG"` invocation written in any skills/**/*.md against the real
// binary's `--help` for that subcommand path.
// Run: node tests/skill_commands_test.mjs
// Regressions caught: a skill naming a subcommand or flag the CLI doesn't have (instructions
// drifting from the CLI), an extractor that silently stops finding invocations, and a skill call
// that leaves out a flag or workflow arg the callee requires; a brownfield run that skips a
// merge's validation rows, or reads its prepared checks before adopting them.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, realpathSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gitPath } from './developer_tools.mjs'
import { removeTempTree } from './temp_tree.mjs'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')

// Prefer an explicit binary, then the checkout's debug build (fresh under `swift test`). The
// shim's cold release build would outlast the repository-script timeout, so it isn't a fallback.
export function swiftgateBinary() {
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
const REQUIRED_BUILD_TASK_ARGS = ['task:', 'plan:', 'worktree:', 'branch:', 'writeSet:', 'taskGate:', 'tests:', 'contextPack:', 'model:', 'review:', 'taskProof:', 'planSurface:', 'buildRun:', 'pluginRoot:']
// The PreToolUse guard denies these without the caller's own literal `--session`.
const SESSION_COMMANDS = ['plan claim', 'plan release', 'plan set', 'index set', 'ledger set', 'build start', 'build finish', 'build merge', 'build cutoff', 'worktree create']

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
  help.cleanup = () => removeTempTree(dir)
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
    removeTempTree(dir)
  }
}

// Imported for its helpers, this file runs no checks and makes no help cache.
const isMain = realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)
const help = isMain ? realHelp() : undefined

const designSkillFiles = () =>
  Object.fromEntries(
    markdownFiles(join(root, 'skills/design')).map(path => [relative(root, path), readFileSync(path, 'utf8')]),
  )

export const buildSkillFiles = () =>
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
    run(gitPath, ['init', '-q', '-b', 'main'])
    run(gitPath, ['-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '--allow-empty', '-m', 'init'])
    const sha = run(gitPath, ['rev-parse', 'HEAD']).trim()
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
    removeTempTree(dir)
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
    run(gitPath, ['commit', '-qam', message])
    return run(gitPath, ['rev-parse', 'HEAD']).trim()
  }
  try {
    mkdirSync(join(dir, 'Sources/Core'), { recursive: true })
    mkdirSync(join(dir, '.harness/runs'), { recursive: true })
    writeFileSync(join(dir, '.gitignore'), '.harness/\n')
    writeFileSync(source, 'public func base() -> Int { 1 }\n')
    writeFileSync(join(dir, 'page.md'), '# page\n')
    run(gitPath, ['init', '-q', '-b', 'main'])
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'init'])
    record(gateRecord('20260101T000000Z-0000aaaa', 'push', run(gitPath, ['rev-parse', 'HEAD']).trim()))
    const steps = [sg(['sprint', 'start', 'walk', '--spec-page', 'page.md', '--slices', '1'])]
    run(gitPath, ['switch', '-q', 'sprint/walk'])
    const surface = commit('public func step() -> Int { 0 }\n', 'surface')
    steps.push(sg(['sprint', 'surface', surface]))
    const extra = commit('public func last() -> Int { 0 }\n', 'extra stub')
    steps.push(sg(['surface-check', extra]))
    writeFileSync(source, 'public func base() -> Int { 1 }\npublic func step() -> Int { 2 }\npublic func last() -> Int { 3 }\n')
    run(gitPath, ['commit', '-qam', 'slice 1'])
    const head = run(gitPath, ['rev-parse', 'HEAD']).trim()
    const mainBase = run(gitPath, ['rev-parse', 'main']).trim()
    record(gateRecord('20260101T000003Z-0000dddd', 'push', head, null, mainBase))
    const fromMain = sg(['sprint', 'slice', '1', '--gate', '20260101T000003Z-0000dddd'])
    assert.deepEqual([fromMain.code, fromMain.report.rule], [1, 'sprint.gate-base'], fromMain.report.message)
    record(gateRecord('20260101T000001Z-0000bbbb', 'push', head, null, surface))
    steps.push(sg(['sprint', 'slice', '1', '--gate', '20260101T000001Z-0000bbbb']))
    assert.deepEqual(steps.map(s => [s.report.verdict, s.code]), Array(4).fill(['GREEN', 0]),
      steps.map(s => s.report.message).join('\n'))
    record(gateRecord('20260101T000002Z-0000cccc', 'ready', head, proofBases(surface, extra)))
    const finish = sg(['sprint', 'finish', '--gate', '20260101T000002Z-0000cccc'])
    return { ...finish, mainMoved: run(gitPath, ['rev-parse', 'main']).trim() === head }
  } finally {
    removeTempTree(dir)
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

// Every `rm` or `mv` a markdown text runs as a shell command without `command ` or `/bin/` before
// it, as `<line>: <code>`. Code means a fenced block or an inline code span; a command starts a
// line, or follows `&&`, `||`, `;`, `|`, `(` or `$(`. A user's `rm -i` alias waits for an answer a
// headless session can't give.
export function bareRemoveOrMove(text) {
  const found = []
  let inFence = false
  for (const [index, line] of text.split('\n').entries()) {
    if (FENCE.test(line)) {
      inFence = !inFence
      continue
    }
    const code = inFence ? [line] : line.split('`').filter((_, i) => i % 2 === 1)
    for (const segment of code) {
      for (const command of segment.split(/&&|\|\||;|\||\$\(|\(/)) {
        if (/^\s*(rm|mv)(\s|$)/.test(command)) found.push(`${index + 1}: ${segment.trim()}`)
      }
    }
  }
  return found
}

// Every markdown file and workflow script under the plugin's skills, agents and workflows.
function shellInstructionFiles() {
  const workflows = readdirSync(join(root, 'workflows')).filter(name => name.endsWith('.js')).map(name => join(root, 'workflows', name))
  return [...markdownFiles(join(root, 'skills')), ...markdownFiles(join(root, 'agents')), ...workflows]
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
    run(gitPath, ['switch', '-q', '-c', 'surface/demo', 'main'])
    writeFileSync(join(dir, 'Sources/Core/Core.swift'), 'public func step() -> Int { 0 }\n', { flag: 'a' })
    run(gitPath, ['commit', '-qam', 'surface'])
    surface = run(gitPath, ['rev-parse', 'HEAD']).trim()
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
      'stop_starts_before_min = 0', 'on_design_conflict = "block"', 'task_proof = "final"',
      'sim_qa = "off"', '',
    ].join('\n'))
    run(gitPath, ['init', '-q', '-b', 'main'])
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'init'])
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
    return { steps, planFile, surface, main: run(gitPath, ['rev-parse', 'main']).trim() }
  } finally {
    removeTempTree(dir)
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

// The build skill's gates on `main`, named by the tier word their line carries: the start's
// green-main check, each merge gate, and the final `ready` gate.
const BUILD_GATE_KINDS = { '<merge_gate>': 'green-main', '<mergeGate>': 'merge', ready: 'final' }
// The build skill's gate lines on `main` as they were before a plan could carry a surface, per
// file in order. A plan without a surface runs exactly these.
const BUILD_GATE_LINES_WITHOUT_SURFACE = {
  'skills/build/SKILL.md': ['check --tier <merge_gate>', 'check --tier <mergeGate>', 'check --tier ready'],
  'skills/build/references/event-loop.md': ['check --tier <mergeGate>', 'check --tier ready <the --proof-base arguments it printed>'],
}

// Every `check` line in the build skill's `files` ({relative path: markdown}) that one of its gates
// on `main` runs: {file, line, kind, words, base}, where `base` is the word after `--base` or null.
function buildGateLines(files) {
  const lines = []
  for (const [file, text] of Object.entries(files)) {
    for (const inv of extractInvocations(text)) {
      if (inv.words[0] !== 'check') continue
      const kind = BUILD_GATE_KINDS[inv.words[inv.words.indexOf('--tier') + 1]]
      if (!kind) continue
      const at = inv.words.findIndex(w => flagOf(w) === '--base')
      lines.push({ file, line: inv.line, kind, words: inv.words, base: at < 0 ? null : inv.words[at + 1] ?? '' })
    }
  }
  return lines
}

/**
 * The gate lines a build of `plan` (its plan.json) runs on `main`, by kind, from the skill's
 * `files`: with a `surfaceCommit`, the lines measuring from it, with the sha filled in; without,
 * the lines that name no base.
 */
export function buildGatesFor(files, plan) {
  const surfaced = typeof plan.surfaceCommit === 'string'
  return buildGateLines(files)
    .filter(gate => (gate.base !== null) === surfaced)
    .map(gate => ({ ...gate, words: gate.words.map(w => (w === '<surfaceCommit>' ? plan.surfaceCommit : w)) }))
}

/**
 * Problems with where the build skill's gates on `main` measure from: a gate line with a base
 * other than `<surfaceCommit>`; a file whose no-base lines differ from the lines before a plan
 * could carry a surface; a no-base line with no `--base <surfaceCommit>` twin in the same file; no
 * `<surfaceCommit>` row in the names table; and a green-main check that runs before step 1 reads
 * the plan surface from plan.json.
 */
export function buildGateBaseProblems(files) {
  const problems = []
  const gates = buildGateLines(files)
  for (const gate of gates) {
    if (gate.base !== null && gate.base !== '<surfaceCommit>') {
      problems.push(`${gate.file}:${gate.line}: the ${gate.kind} gate measures from ${gate.base || 'nothing'}, not <surfaceCommit>`)
    }
  }
  for (const [file, expected] of Object.entries(BUILD_GATE_LINES_WITHOUT_SURFACE)) {
    const plain = gates.filter(gate => gate.file === file && gate.base === null)
    const found = plain.map(gate => gate.words.join(' '))
    if (JSON.stringify(found) !== JSON.stringify(expected)) {
      problems.push(`${file}: a plan without a surface runs ${JSON.stringify(found)}, not ${JSON.stringify(expected)}`)
    }
    for (const gate of plain) {
      const twin = gates.some(other => other.file === file && other.kind === gate.kind && other.base === '<surfaceCommit>'
        && other.words.filter((w, i, all) => flagOf(w) !== '--base' && flagOf(all[i - 1] ?? '') !== '--base').join(' ') === gate.words.join(' '))
      if (!twin) problems.push(`${file}:${gate.line}: the ${gate.kind} gate has no \`--base <surfaceCommit>\` form for a plan with a surface`)
    }
  }
  const skill = files['skills/build/SKILL.md'] ?? ''
  if (!/^\| `<surfaceCommit>` \|[^\n]*`surfaceCommit`/m.test(skill)) problems.push('no `<surfaceCommit>` row in the names table')
  const [start] = numberedSections(skill, /^## 1\. Start\b/)
  const greenMain = gates.find(gate => gate.file === 'skills/build/SKILL.md' && gate.kind === 'green-main')
  const readsSurface = (start?.lines ?? []).findIndex(row => /plan\.json/.test(row) && /surface/.test(row))
  if (greenMain && (readsSurface < 0 || start.firstLine + readsSurface > greenMain.line)) {
    problems.push('the green-main check runs before step 1 reads the plan surface from plan.json')
  }
  return problems
}

/**
 * The environment for a walk whose push gate builds and tests a temp package: git identity, the
 * coverage profile kept in `dir`, and the Swift driver's dSYM step pointed at `true`. Every debug
 * link on the machine queues on `dsymutil`; under load it has sat in uninterruptible wait for 30s
 * with 1s of CPU, longer than the rest of the walk. The walk judges verdicts, which come from the
 * coverage map and test results, never from a dSYM.
 */
function buildingWalkEnvironment(dir) {
  return {
    ...process.env, LLVM_PROFILE_FILE: join(dir, 'gate-%p.profraw'), SWIFT_DRIVER_DSYMUTIL_EXEC: '/usr/bin/true',
    GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.com', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.com',
  }
}

/**
 * Runs the build skill's green-main and merge gate lines for a plan (`gates`, from
 * `buildGatesFor`) through the real binary in a temp repository where `main` just moved to a
 * surface commit that adds an untested module, as `plan surface` leaves it, and `origin/main` is
 * still the commit before it. The merge gate runs after a task commit that changes that module
 * with no test. The module is `host_testable = false`, so impact is the only rule its new
 * untested code trips at push. Returns each run's kind, verdict and gating rules.
 */
export function buildGateWalk(gates) {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-build-gates-'))
  const env = buildingWalkEnvironment(dir)
  const run = (file, args) => execFileSync(file, args, { encoding: 'utf8', cwd: dir, env })
  const write = (path, text) => {
    mkdirSync(dirname(join(dir, path)), { recursive: true })
    writeFileSync(join(dir, path), text)
  }
  const manifest = extra => [
    '// swift-tools-version: 6.0', 'import PackageDescription', '', 'let package = Package(', '  name: "Core",',
    `  products: [.library(name: "Core", targets: ["Core"])${extra ? ', .library(name: "Feed", targets: ["Feed"])' : ''}],`,
    '  targets: [', '    .target(name: "Core"),', ...(extra ? ['    .target(name: "Feed", dependencies: ["Core"]),'] : []),
    '    .testTarget(name: "CoreTests", dependencies: ["Core"]),', '  ]', ')', '',
  ].join('\n')
  const module = (name, extra) => ['', '[[modules]]', `name = "${name}"`, 'kind = "library"', ...extra, 'reason = "plain value helpers"', ''].join('\n')
  const config = [
    'schema = 1', 'xcode = "26.2"', 'app_scheme = "App"', 'packages = ["Packages/*"]', '',
    '[simulator]', 'device = "iPhone 17"', 'os = "26.2"', module('Core', []),
  ].join('\n')
  const gate = (kind, words) => {
    const args = words.map(w => (w === '<merge_gate>' || w === '<mergeGate>' ? 'push' : w))
    assert.ok(!args.some(w => /^<.*>$/.test(w)), `the walk has no value for a word of \`${words.join(' ')}\``)
    let out
    try {
      out = run(binary, [...args, '--json'])
    } catch (error) {
      out = error.stdout
    }
    const report = JSON.parse(out)
    const gating = report.findings.filter(f => f.severity === 'blocker' || f.severity === 'major').map(f => `${f.rule} ${f.file}`)
    return { kind, verdict: report.verdict, gating }
  }
  try {
    write('.gitignore', '.harness/\n.build/\n')
    write('.swiftgate.toml', config)
    write('Packages/Core/Package.swift', manifest(false))
    write('Packages/Core/Sources/Core/Core.swift', 'public func base() -> Int { 1 }\n')
    write('Packages/Core/Tests/CoreTests/CoreTests.swift',
      'import Testing\n@testable import Core\n\n@Test("base is one — catches a changed base") func baseIsOne() { #expect(base() == 1) }\n')
    run(gitPath, ['init', '-q', '-b', 'main'])
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'init'])
    run(gitPath, ['update-ref', 'refs/remotes/origin/main', 'HEAD'])
    write('.swiftgate.toml', config + module('Feed', ['host_testable = false']))
    write('Packages/Core/Package.swift', manifest(true))
    write('Packages/Core/Sources/Feed/Feed.swift', 'public struct Feed: Sendable {\n  public init() {}\n  public func count() -> Int { 0 }\n}\n')
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'surface'])
    const surface = run(gitPath, ['rev-parse', 'HEAD']).trim()
    const fill = words => words.map(w => (w === '<surfaceCommit>' ? surface : w))
    const surfaceCheck = gate('surface-check', ['surface-check', surface])
    assert.equal(surfaceCheck.verdict, 'GREEN', `the walk's surface is not all stubs: ${surfaceCheck.gating.join(', ')}`)
    const results = []
    const greenMain = gates.find(g => g.kind === 'green-main')
    const merge = gates.find(g => g.kind === 'merge')
    if (greenMain) results.push(gate('green-main', fill(greenMain.words)))
    write('Packages/Core/Sources/Feed/Feed.swift', 'public struct Feed: Sendable {\n  public init() {}\n  public func count() -> Int { 3 }\n}\n')
    run(gitPath, ['commit', '-qam', 'task'])
    if (merge) results.push(gate('merge', fill(merge.words)))
    return { surface, results }
  } finally {
    removeTempTree(dir)
  }
}

/**
 * The rule the build skill's start states for taking a surface's green-main findings as the
 * baseline without asking: the rule id it names, the git command that lists a module's files the
 * surface commit changed, and the one that lists its files before the surface. Null when step 1
 * states no such rule; `<surfaceCommit>` and `<file>` stay placeholders.
 */
export function surfaceBaselineRule(skill) {
  const [start] = numberedSections(skill, /^## 1\. Start\b/)
  const paragraph = (start?.lines ?? []).join('\n').split(/\n\s*\n/).find(p => /\bwithout\s+asking\b/.test(p))
  if (!paragraph) return null
  const flat = paragraph.replace(/\s+/g, ' ')
  const rule = /`([a-z0-9-]+\.[a-z0-9-]+)` for a module the surface commit added/.exec(flat)?.[1]
  const changed = /`(git diff [^`]+)` lists files/.exec(flat)?.[1]
  const before = /`(git ls-tree [^`]+)` lists none/.exec(flat)?.[1]
  if (!rule || !changed || !before) return null
  return { rule, changed, before }
}

/**
 * Problems with how the build skill takes a surface's untested new modules as the baseline: no
 * rule in step 1 (`surfaceBaselineRule`), no halt for any other gating finding beside them, a
 * report that doesn't name the baseline taken, a final gate that doesn't refuse it, and a merge
 * gate that passes only on exactly the baseline.
 */
export function surfaceBaselineProblems(skill) {
  const problems = []
  const rule = surfaceBaselineRule(skill)
  if (!rule) problems.push('step 1 takes no baseline without asking for a surface\'s untested new modules')
  for (const [name, command] of [['changed', rule?.changed], ['before', rule?.before]]) {
    if (command && !(command.includes('<surfaceCommit>') && command.includes('<file>'))) {
      problems.push(`the ${name} command \`${command}\` doesn't name both <surfaceCommit> and <file>`)
    }
  }
  const [start] = numberedSections(skill, /^## 1\. Start\b/)
  const paragraph = (start?.lines ?? []).join('\n').split(/\n\s*\n/).find(p => /\bwithout\s+asking\b/.test(p)) ?? ''
  if (!/\bany other gating finding\b[^.]*\bhalts\b/i.test(paragraph.replace(/\s+/g, ' '))) {
    problems.push('step 1 never halts on another gating finding beside the surface\'s')
  }
  const report = /\n## Report\n([^]*?)\n## /.exec(skill)?.[1] ?? ''
  if (!/baseline[^.;]*without asking/.test(report.replace(/\s+/g, ' '))) problems.push('the report never names a baseline taken without asking')
  const [finish] = numberedSections(skill, /^## 4\. Finish\b/)
  if (!/\bno baseline\b/.test((finish?.lines ?? []).join(' ').replace(/\s+/g, ' '))) problems.push('the final gate never says it takes no baseline')
  if (/\bexactly the (?:step 1 )?baseline/.test(skill.replace(/\s+/g, ' '))) {
    problems.push('a merge gate passes only on exactly the baseline, so a task that clears 1 of its findings reads as red')
  }
  return problems
}

/**
 * Walks the build skill's start on a plan with a surface, through the real binary, in a temp
 * repository where `main` just moved to a surface commit that adds the host-testable module
 * `Feed` with no test target. 2 more reds sit beside it: a module `Legacy` with no tests that
 * `main` held before the surface, which the surface touches too, and a commit on `main` after the
 * surface that adds `Core` code its new test doesn't run. 1 gate run gives all 3 findings, so each
 * set the start decides on comes from a real run. Runs the skill's green-main
 * line, then decides as its `rule` (from `surfaceBaselineRule`, null for none) says, running the
 * rule's git commands. Returns the gate's verdict, its gating findings as `rule file`, and the
 * decision, `baseline` (every finding taken without asking) or `halt`, on `Feed`'s finding alone
 * (`alone`), on all of them (`all`), and on `Feed`'s beside each other one (`beside`, by that one).
 */
export function surfaceBaselineWalk(gates, rule) {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'skill-commands-baseline-'))
  const env = buildingWalkEnvironment(dir)
  const run = (file, args) => execFileSync(file, args, { encoding: 'utf8', cwd: dir, env })
  const write = (path, text) => {
    mkdirSync(dirname(join(dir, path)), { recursive: true })
    writeFileSync(join(dir, path), text)
  }
  const manifest = names => [
    '// swift-tools-version: 6.0', 'import PackageDescription', '', 'let package = Package(', '  name: "Core",',
    `  products: [${names.map(name => `.library(name: "${name}", targets: ["${name}"])`).join(', ')}],`,
    '  targets: [', ...names.map(name => `    .target(name: "${name}"${name === 'Core' ? '' : ', dependencies: ["Core"]'}),`),
    '    .testTarget(name: "CoreTests", dependencies: ["Core"]),', '  ]', ')', '',
  ].join('\n')
  const module = name => ['', '[[modules]]', `name = "${name}"`, 'kind = "library"', 'reason = "plain value helpers"', ''].join('\n')
  const config = names => [
    'schema = 1', 'xcode = "26.2"', 'app_scheme = "App"', 'packages = ["Packages/*"]', '',
    '[simulator]', 'device = "iPhone 17"', 'os = "26.2"', ...names.map(module),
  ].join('\n')
  const before = ['Core', 'Legacy']
  try {
    write('.gitignore', '.harness/\n.build/\n')
    write('.swiftgate.toml', config(before))
    write('Packages/Core/Package.swift', manifest(before))
    write('Packages/Core/Sources/Core/Core.swift', 'public func base() -> Int { 1 }\n')
    write('Packages/Core/Tests/CoreTests/CoreTests.swift',
      'import Testing\n@testable import Core\n\n@Test("base is one — catches a changed base") func baseIsOne() { #expect(base() == 1) }\n')
    write('Packages/Core/Sources/Legacy/Legacy.swift', 'public func legacy() -> Int { 2 }\n')
    run(gitPath, ['init', '-q', '-b', 'main'])
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'init'])
    run(gitPath, ['update-ref', 'refs/remotes/origin/main', 'HEAD'])
    write('.swiftgate.toml', config([...before, 'Feed']))
    write('Packages/Core/Package.swift', manifest([...before, 'Feed']))
    write('Packages/Core/Sources/Feed/Feed.swift', 'public struct Feed: Sendable {\n  public init() {}\n  public func count() -> Int { 0 }\n}\n')
    write('Packages/Core/Sources/Legacy/Later.swift', 'public func later() -> Int { 0 }\n')
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'surface'])
    const surface = run(gitPath, ['rev-parse', 'HEAD']).trim()
    const surfaceCheck = JSON.parse(run(binary, ['surface-check', surface, '--json']))
    assert.equal(surfaceCheck.verdict, 'GREEN', 'the walk\'s surface is not all stubs')
    write('Packages/Core/Sources/Core/Core.swift', 'public func base() -> Int { 1 }\n\npublic func extra(_ value: Int) -> Int {\n  value * 3\n}\n')
    writeFileSync(join(dir, 'Packages/Core/Tests/CoreTests/CoreTests.swift'),
      '\n@Test("base stays positive — catches a negated base") func baseIsPositive() { #expect(base() > 0) }\n', { flag: 'a' })
    run(gitPath, ['commit', '-qam', 'later'])
    const greenMain = gates.find(g => g.kind === 'green-main')
    assert.ok(greenMain, 'the skill has no green-main line for a plan with a surface')
    const args = greenMain.words.map(w => (w === '<merge_gate>' ? 'push' : w === '<surfaceCommit>' ? surface : w))
    let out
    try {
      out = run(binary, [...args, '--json'])
    } catch (error) {
      out = error.stdout
    }
    const report = JSON.parse(out)
    const gating = report.findings.filter(f => f.severity === 'blocker' || f.severity === 'major')
    const git = (command, file) => {
      const words = command.split(/\s+/).map(w => w.replaceAll('<surfaceCommit>', surface).replaceAll('<file>', file))
      assert.equal(words[0], 'git', `the rule's command is not git: ${command}`)
      return run(gitPath, words.slice(1)).trim()
    }
    const addedBySurface = finding => rule !== null && finding.rule === rule.rule
      && git(rule.changed, finding.file) !== '' && git(rule.before, finding.file) === ''
    const decide = findings => (findings.length === 0 ? 'green' : findings.every(addedBySurface) ? 'baseline' : 'halt')
    const name = f => `${f.rule} ${f.file}`
    const feed = gating.filter(f => f.file === 'Packages/Core/Sources/Feed')
    const beside = Object.fromEntries(gating.filter(f => !feed.includes(f)).map(f => [name(f), decide([...feed, f])]))
    return { verdict: report.verdict, gating: gating.map(name), alone: decide(feed), all: decide(gating), beside }
  } finally {
    removeTempTree(dir)
  }
}

// The stored `public let` fields of a Swift struct, read from its source, so a check against them
// moves with the type.
function swiftStoredFields(source, typeName) {
  const body = source.split(new RegExp(`\\bstruct ${typeName}\\b[^{]*\\{`))[1] ?? ''
  const fields = body.slice(0, body.search(/\n\}/))
  return [...fields.matchAll(/^\s*public let (\w+): ([^\n=]+)/gm)].map(m => ({ name: m[1], optional: m[2].trim().endsWith('?') }))
}

// The validation table's shape and the rule ids `plan-lint` can report, as the gate declares them.
// The screen rule needs the repository's app areas, so it counts only once `plan-lint` passes them.
function validationContract() {
  const table = readFileSync(join(root, 'gate/Sources/SwiftGateDomain/Plan/ValidationTable.swift'), 'utf8')
  const lint = readFileSync(join(root, 'gate/Sources/SwiftGateDomain/Plan/PlanLintValidation.swift'), 'utf8')
  const command = readFileSync(join(root, 'gate/Sources/SwiftGateCLI/Commands/PlanLintCommand.swift'), 'utf8')
  const screenRule = /screenWithoutFlowRuleID = "([^"]+)"/.exec(lint)?.[1]
  const lintCall = (command.split('PlanLintValidation.findings(')[1] ?? '').split(/\n\s*\}/)[0]
  const passesAppAreas = /\bappAreas:/.test(lintCall)
  const layerBody = (table.split(/\benum ValidationLayer\b[^{]*\{/)[1] ?? '').split(/\n\}/)[0]
  return {
    tableFields: swiftStoredFields(table, 'ValidationTable').map(f => f.name),
    rowFields: swiftStoredFields(table, 'ValidationRow'),
    unitOnlyFields: swiftStoredFields(table, 'ValidationUnitOnly').map(f => f.name),
    layers: [...layerBody.matchAll(/^\s*case (\w+)/gm)].map(m => m[1]),
    ruleIDs: [...lint.matchAll(/RuleID = "([^"]+)"/g)].map(m => m[1]).filter(id => passesAppAreas || id !== screenRule),
  }
}

// Where the plan skill and its decomposer fall short of writing the validation table a design plan
// keeps beside its ledger: the decomposer's contract returns rows in the table's shape, a design
// with 2 or more UI tasks gets a validation task, and the skill writes `validation.json` before
// `plan-lint` and names the rules that check it.
function validationTableProblems({ plan, stateFiles, agent }, contract) {
  const problems = []
  const step5 = (plan.split('\n## 5. ')[1] ?? '').split('\n## ')[0]
  const write = step5.search(/<plans>\/<slug>\/validation\.json/)
  const lint = extractInvocations(step5).find(inv => inv.words[0] === 'plan-lint')
  const lintAt = lint ? step5.split('\n').slice(0, lint.line - 1).join('\n').length : -1
  if (write < 0) problems.push('step 5 never writes `<plans>/<slug>/validation.json`')
  else if (lintAt >= 0 && write > lintAt) problems.push('step 5 writes `validation.json` after `plan-lint` reads it')
  const specPage = (plan.split('\n### A spec-page plan\n')[1] ?? '').split(/\n#{2,3} /)[0].replace(/\s+/g, ' ')
  if (!/writes no `validation\.json`/.test(specPage)) problems.push('the spec-page section never says a spec-page plan writes no `validation.json`')
  for (const id of contract.ruleIDs) if (!plan.includes(`\`${id}\``)) problems.push(`the plan skill never names \`${id}\``)

  const shape = (stateFiles.split('\n## `validation.json`\n')[1] ?? '').split('\n## ')[0]
  const shapeJSON = /```json\n([\s\S]*?)\n```/.exec(shape)?.[1]
  let stored
  try { stored = shapeJSON && JSON.parse(shapeJSON) } catch { stored = undefined }
  if (!stored) problems.push('the state files reference has no `validation.json` JSON shape')
  else {
    const keys = Object.keys(stored).sort()
    if (JSON.stringify(keys) !== JSON.stringify([...contract.tableFields].sort())) problems.push(`the reference's \`validation.json\` keys are ${keys.join(', ')}, not ${contract.tableFields.join(', ')}`)
    if (stored.schemaVersion !== 1) problems.push('the reference\'s `validation.json` has no `schemaVersion` 1')
  }

  const block = /```json\n([\s\S]*?)\n```/.exec((agent.split('\n## Output contract\n')[1] ?? '').split('\n## ')[0])?.[1]
  let reply
  try { reply = block && JSON.parse(block) } catch { reply = undefined }
  if (!reply) return [...problems, 'the decomposer\'s output contract has no JSON example']
  const validation = reply.validation
  const wantKeys = contract.tableFields.filter(f => f !== 'schemaVersion').sort()
  if (!validation || JSON.stringify(Object.keys(validation).sort()) !== JSON.stringify(wantKeys)) {
    problems.push(`the decomposer's reply has no \`validation\` object with ${wantKeys.join(', ')}`)
  } else {
    const taskIDs = new Set((reply.tasks ?? []).map(t => t.id))
    const names = contract.rowFields.map(f => f.name)
    const required = contract.rowFields.filter(f => !f.optional).map(f => f.name)
    for (const row of validation.rows) {
      const where = `the decomposer's ${row.requirement} ${row.layer} row`
      const extra = Object.keys(row).filter(k => !names.includes(k))
      const missing = required.filter(k => !(k in row))
      if (extra.length || missing.length) problems.push(`${where} has keys ${Object.keys(row).join(', ')}, not ${names.join(', ')}`)
      if (!contract.layers.includes(row.layer)) problems.push(`${where} has a layer outside ${contract.layers.join(', ')}`)
      for (const id of [...(row.runsAfter ?? []), row.writer]) if (!taskIDs.has(id)) problems.push(`${where} names \`${id}\`, which is no task in the reply`)
    }
    for (const entry of validation.unitOnly) {
      if (JSON.stringify(Object.keys(entry).sort()) !== JSON.stringify([...contract.unitOnlyFields].sort())) problems.push(`the decomposer's unit-only entry for ${entry.requirement} has keys ${Object.keys(entry).join(', ')}, not ${contract.unitOnlyFields.join(', ')}`)
    }
    const checked = new Set([...validation.rows, ...validation.unitOnly].map(r => r.requirement))
    const reqs = [...new Set((reply.tasks ?? []).flatMap(t => t.covers ?? []).filter(id => id.startsWith('req-')))]
    for (const id of reqs) if (!checked.has(id)) problems.push(`the decomposer's example leaves ${id} with no row and no unit-only reason`)
  }
  const prose = agent.replace(/\s+/g, ' ')
  if (!/2 or more tasks build UI[^.]*validation task/.test(prose)) problems.push('the decomposer never adds a validation task when 2 or more tasks build UI')
  for (const id of contract.ruleIDs) if (!agent.includes(`\`${id}\``)) problems.push(`the decomposer's fix round never names \`${id}\``)
  return problems
}

// The text of the `## <heading>…` section of `text`, without the next `## ` section.
function h2Section(text, heading) {
  const padded = `\n${text}`
  const at = padded.indexOf(`\n## ${heading}`)
  return at < 0 ? '' : padded.slice(at + 1).split(/\n## /)[0]
}

/**
 * Where a skill that drives `swiftgate` can lose its first call to a cold shim build: a release
 * build outlasts the Bash tool's default 120 s timeout, the call moves to the background, and a
 * headless session that ends its turn kills it with no verdict. Each problem is 1 string: no
 * `## Foreground work` section before step 1, or one that never warms the binary with
 * `"$SG" --version`, never names the 600000 ms timeout, or never rules out `run_in_background`.
 */
export function warmUpProblems(text) {
  const padded = `\n${text}`
  const at = padded.indexOf('\n## Foreground work')
  if (at < 0) return ['no `## Foreground work` section']
  const problems = []
  const firstStep = padded.search(/\n## 1\. /)
  if (firstStep >= 0 && at > firstStep) problems.push('`## Foreground work` comes after step 1')
  const section = h2Section(text, 'Foreground work')
  if (!extractInvocations(section).some(inv => inv.words[0] === '--version')) {
    problems.push('`## Foreground work` never warms the binary with `"$SG" --version`')
  }
  if (!/\b600000\b/.test(section)) problems.push('`## Foreground work` never sets the Bash timeout to 600000')
  if (!/\brun_in_background\b/.test(section)) problems.push('`## Foreground work` never rules out `run_in_background`')
  return problems
}

const WARMED_SKILLS = ['qa', 'build', 'sprint', 'run']

const runValidationFileNames = [
  'skills/run/SKILL.md', 'skills/run/references/plan-shape.md', 'skills/qa/references/validation-worker.md',
  'skills/build/references/event-loop.md',
]
const runValidationFiles = () => Object.fromEntries(runValidationFileNames.map(name =>
  [name, existsSync(join(root, name)) ? readFileSync(join(root, name), 'utf8') : '']))

// Where the brownfield run falls short of validating each merge: `qa adopt` copies the validation
// worker's checks into plan state before `qa run --at-base` reads them there, every merge runs
// `qa run --after <task>` and a red one undoes the merge, `final` runs every merged row, flow rows
// stay with `xcode` areas, the contract names what the checks target, and the validation task
// follows the shared worker brief but writes only `.harness/qa/`, since no commit carries that
// folder and its task never merges.
function runValidationProblems(files) {
  const problems = []
  const skill = files['skills/run/SKILL.md'] ?? ''
  const shape = files['skills/run/references/plan-shape.md'] ?? ''
  const worker = files['skills/qa/references/validation-worker.md'] ?? ''
  const loop = files['skills/build/references/event-loop.md'] ?? ''
  const qaCalls = text => extractInvocations(text).filter(inv => inv.words[0] === 'qa')
  const isRun = inv => inv.words[1] === 'run'
  const afterTask = inv => isRun(inv) && inv.words[inv.words.indexOf('--after') + 1] === '<task>'

  const skillCalls = qaCalls(skill)
  const adopt = skillCalls.find(inv => inv.words[1] === 'adopt')
  const atBase = skillCalls.find(inv => isRun(inv) && inv.words.includes('--at-base'))
  if (!adopt) problems.push('the run skill never runs `swiftgate qa adopt`')
  if (!atBase) problems.push('the run skill never runs `swiftgate qa run --at-base`')
  if (adopt && atBase && atBase.line < adopt.line) {
    problems.push('the run skill runs `qa run --at-base` before `qa adopt` copies the checks it reads')
  }
  if (!qaCalls(h2Section(skill, '7. ')).some(afterTask)) {
    problems.push('step 7 never runs `swiftgate qa run --after <task>` after a merge')
  }
  const finalCalls = qaCalls(h2Section(skill, '8. ')).filter(isRun)
  if (!finalCalls.some(inv => !inv.words.includes('--after') && !inv.words.includes('--at-base'))) {
    problems.push('step 8 never runs `swiftgate qa run` over every merged row')
  }
  if (!/`flow` rows?[^.]*`xcode` area/.test(skill.replace(/\s+/g, ' '))) {
    problems.push('the run skill never keeps `flow` rows to `xcode` areas')
  }
  const contract = h2Section(skill, '6. ').replace(/\s+/g, ' ')
  for (const target of ['identifier', 'route', 'storage key', 'log line']) {
    if (!contract.includes(target)) problems.push(`the contract step never names a check's ${target}s`)
  }

  const after = h2Section(loop, 'After each merge')
  if (!after) problems.push('the build loop has no `## After each merge` step')
  else {
    if (!qaCalls(after).some(afterTask)) problems.push('the after-merge step never runs `swiftgate qa run --after <task>`')
    if (!extractInvocations(after).some(inv => inv.words.join(' ').startsWith('build merge <slug> <task> --undo'))) {
      problems.push('the after-merge step never undoes a merge whose rows read red')
    }
  }

  const blocks = [...shape.matchAll(/```markdown\n([\s\S]*?)\n```/g)].map(m => m[1])
  const task = blocks.find(block => /^### \S+-validation$/m.test(block))
  if (!task) problems.push('the plan shape has no `### <slug>-validation` task example')
  else {
    const writes = /^- Writes: (.*)$/m.exec(task)?.[1] ?? ''
    const paths = writes.split(',').map(p => p.trim()).filter(Boolean)
    if (!paths.length) problems.push('the validation task example has no write set')
    for (const path of paths) {
      if (!path.startsWith('.harness/qa/')) problems.push(`the validation task example writes \`${path}\`, outside \`.harness/qa/\``)
    }
  }
  if (!worker) problems.push('no validation worker brief')
  if (!skill.includes('skills/qa/references/validation-worker.md')) {
    problems.push('the run skill never hands its validation task the shared validation worker brief')
  }
  if (!/validation task[^.]*commits nothing/.test(h2Section(skill, '7. ').replace(/\s+/g, ' '))) {
    problems.push('step 7 never says the validation task commits nothing')
  }
  return problems
}

const callerQAFileNames = [
  'skills/build/SKILL.md', 'skills/build/references/event-loop.md', 'skills/sprint/SKILL.md',
  'skills/ship/SKILL.md', 'skills/validate/SKILL.md', 'skills/qa/SKILL.md',
]
const callerQAFiles = () => Object.fromEntries(callerQAFileNames.map(name =>
  [name, existsSync(join(root, name)) ? readFileSync(join(root, name), 'utf8') : '']))

// The key names a Swift `CodingKeys` enum encodes, its raw value where it gives one.
function codingKeys(source, typeName) {
  const type = source.split(new RegExp(`\\bstruct ${typeName}\\b`))[1] ?? ''
  const body = (type.split(/enum CodingKeys: String, CodingKey \{/)[1] ?? '').split('}')[0]
  return [...body.matchAll(/case ([^\n]+)/g)].flatMap(m => m[1].split(',')).map(part => {
    const raw = /= "([^"]+)"/.exec(part)
    return raw ? raw[1] : part.trim()
  }).filter(Boolean)
}

// The keys `sim verify` writes to `sim/report.json` and `qa run` to `qa/report.json` and each of
// its rows, read from the types that encode them, so the validate skill's names move with them.
function reportKeys() {
  const sim = readFileSync(join(root, 'gate/Sources/SwiftGateDomain/SimQA/SimEvidenceRules.swift'), 'utf8')
  const json = (sim.split(/func json\(\) -> Data \{/)[1] ?? '').split(/\n\s*return\b/)[0]
  const findings = json.split('"findings"')[0]
  return {
    sim: [...findings.matchAll(/"(\w+)":/g)].map(m => m[1]).concat('findings'),
    qa: codingKeys(readFileSync(join(root, 'gate/Sources/SwiftGateDomain/QA/QAReport.swift'), 'utf8'), 'QAReport'),
    row: codingKeys(readFileSync(join(root, 'gate/Sources/SwiftGateDomain/QA/QARow.swift'), 'utf8'), 'QARow'),
  }
}

// The backticked names after `<lead>` in flattened text: "`a`, `b` and `c`".
function keysAfter(text, lead) {
  const at = text.indexOf(lead)
  if (at < 0) return null
  const list = /^((?:`[^`]+`(?:,? and |, )?)+)/.exec(text.slice(at + lead.length))?.[1] ?? ''
  return [...list.matchAll(/`([^`]+)`/g)].map(m => m[1].replace(/\[\]$/, ''))
}

const CALLERS = ['skills/build/SKILL.md', 'skills/sprint/SKILL.md', 'skills/ship/SKILL.md']

// Where the callers fall short of running simulator QA (design §8.2, amendment §9): build, sprint
// and ship each name `/swift-harness:qa` under the preset's `sim_qa`, none still prints
// `validate: not configured`, the build's `validate` stage runs `qa run --final` before the skill
// and prints `validate: sim_qa off` when the key is off, the sprint's comes after `sprint finish`,
// the build loop hands a design plan's validation task the shared brief and links its after-merge
// step, the qa skill knows `--final`, and `/swift-validate`'s "Simulator QA" rows read only keys
// `sim verify` and `qa run` write.
function callerQAProblems(files, keys) {
  const problems = []
  const text = name => files[name] ?? ''
  const flat = name => text(name).replace(/\s+/g, ' ')
  for (const name of CALLERS) {
    if (!text(name).includes('/swift-harness:qa')) problems.push(`${name} never runs \`/swift-harness:qa\``)
    if (!text(name).includes('`sim_qa`')) problems.push(`${name} never reads the preset's \`sim_qa\``)
  }
  for (const name of Object.keys(files)) {
    if (text(name).includes('validate: not configured')) problems.push(`${name} still prints \`validate: not configured\``)
  }
  const qaRuns = section => extractInvocations(section).filter(inv => inv.words[0] === 'qa' && inv.words[1] === 'run')

  const finish = h2Section(text('skills/build/SKILL.md'), '4. Finish')
  const final = qaRuns(finish).find(inv => inv.words.includes('--final') && inv.words.includes('--plan'))
  if (!final) problems.push('the build\'s validate stage never runs `swiftgate qa run --plan <slug> --final`')
  const skillAt = finish.split('\n').findIndex(line => line.includes('/swift-harness:qa')) + 1
  if (!skillAt) problems.push('the build\'s validate stage never runs `/swift-harness:qa`')
  else if (final && final.line > skillAt) problems.push('the build\'s validate stage runs `/swift-harness:qa` before `qa run --final`')
  if (!finish.includes('`validate: sim_qa off`')) problems.push('the build\'s validate stage never prints `validate: sim_qa off`')
  if (!text('skills/build/SKILL.md').includes('references/event-loop.md#after-each-merge')) {
    problems.push('the build skill\'s completion step never links the after-merge step')
  }
  const loop = text('skills/build/references/event-loop.md')
  if (!h2Section(loop, 'Validate stage')) problems.push('the build loop has no `## Validate stage` section')
  if (!h2Section(loop, 'Validation task').includes('skills/qa/references/validation-worker.md')) {
    problems.push('the build loop never hands a plan\'s validation task the shared validation worker brief')
  }

  const sprint = h2Section(text('skills/sprint/SKILL.md'), '6. Finish')
  const finishAt = extractInvocations(sprint).find(inv => inv.words[0] === 'sprint' && inv.words[1] === 'finish')?.line ?? 0
  const sprintQA = sprint.split('\n').findIndex(line => line.includes('/swift-harness:qa')) + 1
  if (!sprintQA || sprintQA < finishAt) problems.push('the sprint never runs `/swift-harness:qa` after `sprint finish`')
  if (!sprint.includes('`validate: sim_qa off`')) problems.push('the sprint never prints `validate: sim_qa off`')

  if (!qaRuns(text('skills/qa/SKILL.md')).some(inv => inv.words.includes('--final'))) {
    problems.push('the qa skill never names `qa run --final`')
  }

  const validate = flat('skills/validate/SKILL.md')
  if (!/\| Simulator QA \|/.test(validate)) problems.push('the validate block has no "Simulator QA" row')
  if (!/Not run[^.]*simulator QA/i.test(validate)) problems.push('the validate skill never lists a skipped simulator QA under "Not run"')
  for (const [lead, known, needed] of [
    ['`sim/report.json` keys ', keys.sim, ['runID', 'verdict', 'stepCount']],
    ['`qa/report.json` keys ', keys.qa, ['runID', 'rows']],
    ['row\'s keys ', keys.row, ['requirement', 'layer', 'check', 'result', 'evidence']],
  ]) {
    const named = keysAfter(validate, lead)
    if (!named) {
      problems.push(`the validate skill never reads ${lead.trim()}`)
      continue
    }
    for (const key of named) if (!known.includes(key)) problems.push(`the validate skill reads ${lead.trim()} \`${key}\`, which nothing writes`)
    for (const key of needed) if (!named.includes(key)) problems.push(`the validate skill never reads ${lead.trim()} \`${key}\``)
  }
  return problems
}

const planValidationFiles = () => ({
  plan: readFileSync(join(root, 'skills/plan/SKILL.md'), 'utf8'),
  stateFiles: readFileSync(join(root, 'skills/plan/references/state-files.md'), 'utf8'),
  agent: readFileSync(join(root, 'agents/design-decomposer.md'), 'utf8'),
})

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
      ['events span start', '--phase'], ['events span start', '--build-run'], ['events span end', '--outcome'],
    ]) assert.ok(has(path, flag), `the build skill never runs \`swiftgate ${path} ${flag}\``)
    const unsessioned = resolved.filter(r => SESSION_COMMANDS.includes(r.path) && !r.flags.includes('--session'))
    assert.deepEqual(unsessioned.map(r => `${r.file}:${r.line} ${r.path}`), [])
  },

  'the run skill names every brownfield command with the flags the CLI has — catches a run step calling a command or flag that drifted'() {
    const { problems, resolved } = scanSkills(join(root, 'skills/run'), help, root)
    assert.deepEqual(problems, [])
    const has = (path, flag) => resolved.some(r => r.path === path && (!flag || r.flags.includes(flag)))
    for (const [path, flag] of [
      ['discover', '--json'], ['discover', '--set'], ['discover', '--drop'], ['discover', '--reason'],
      ['events list', '--kind'], ['allow', '--reason'], ['plan import', '--json'], ['build start', '--preset'],
      ['build start', '--session'], ['check', '--tier'], ['check', '--base'], ['run report', null],
      ['events span start', '--phase'], ['events span start', '--build-run'], ['events span end', '--outcome'],
    ]) assert.ok(has(path, flag), `the run skill never runs \`swiftgate ${path}${flag ? ` ${flag}` : ''}\``)
    const unsessioned = resolved.filter(r => SESSION_COMMANDS.includes(r.path) && !r.flags.includes('--session'))
    assert.deepEqual(unsessioned.map(r => `${r.file}:${r.line} ${r.path}`), [])
    const { resolved: bootstrap } = scanSkills(join(root, 'skills/bootstrap'), help, root)
    assert.ok(bootstrap.some(r => r.path === 'discover' && r.flags.includes('--apply')), 'the bootstrap skill never runs `swiftgate discover --apply`')
  },

  'the run skill and the build loop name every `swiftgate qa` command and flag a validated run needs, each as the CLI has it — catches a validation step calling a qa flag that drifted'() {
    const run = scanSkills(join(root, 'skills/run'), help, root)
    const build = scanSkills(join(root, 'skills/build'), help, root)
    assert.deepEqual([...run.problems, ...build.problems], [])
    const qa = [...run.resolved, ...build.resolved].filter(r => r.path.startsWith('qa'))
    const has = (path, flag, file) => qa.some(r => r.path === path && (!flag || r.flags.includes(flag)) && (!file || r.file.startsWith(file)))
    for (const [path, flag, file] of [
      ['qa adopt', '--json', 'skills/run/SKILL.md'], ['qa run', '--at-base', 'skills/run/SKILL.md'],
      ['qa run', '--after', 'skills/run/SKILL.md'], ['qa run', '--plan', 'skills/run/SKILL.md'],
      ['qa run', '--json', 'skills/run/SKILL.md'],
      ['qa run', '--after', 'skills/build/references/event-loop.md'],
    ]) assert.ok(has(path, flag, file), `${file} never runs \`swiftgate ${path} ${flag}\``)
  },

  'the brownfield run adopts its prepared checks before their red run, validates each merge, runs every row at final and keeps the validation task to .harness/qa/ — catches a merge that skips its rows or a validation task that commits'() {
    assert.deepEqual(runValidationProblems(runValidationFiles()), [])
  },

  'build, sprint and ship run simulator QA under the preset\'s sim_qa, and /swift-validate reports it from the keys sim verify and qa run write — catches a caller still skipping QA or a validate row naming a key no report holds'() {
    const keys = reportKeys()
    for (const key of ['runID', 'verdict', 'stepCount', 'findings']) assert.ok(keys.sim.includes(key), `sim/report.json keys read as ${keys.sim}`)
    for (const key of ['runID', 'final', 'rows']) assert.ok(keys.qa.includes(key), `qa/report.json keys read as ${keys.qa}`)
    for (const key of ['requirement', 'layer', 'check', 'result', 'evidence', 'ms']) assert.ok(keys.row.includes(key), `qa/report.json row keys read as ${keys.row}`)
    assert.deepEqual(callerQAProblems(callerQAFiles(), keys), [])
    const { problems, resolved } = scanSkills(join(root, 'skills/build'), help, root)
    assert.deepEqual(problems, [])
    assert.ok(resolved.some(r => r.path === 'qa run' && r.flags.includes('--final') && r.file === 'skills/build/SKILL.md'), 'the build skill never runs `swiftgate qa run --final` as the CLI has it')
  },

  'the caller QA check names each gap — catches a checker that passes anything'() {
    const keys = { sim: ['runID', 'verdict', 'stepCount'], qa: ['runID', 'rows'], row: ['requirement', 'layer', 'check', 'result', 'evidence'] }
    const files = {
      'skills/build/SKILL.md': [
        '## 3. On each completion', '', 'Merge it.', '',
        '## 4. Finish', '', '1. Run `/swift-harness:qa` when `sim_qa` is `changed`.', '2. `"$SG" qa run --plan <slug> --final --json`.',
        '3. The `validate` stage: print `validate: not configured` and go on.', '',
      ].join('\n'),
      'skills/build/references/event-loop.md': '## Validation task\n\nFollow the brief.\n',
      'skills/sprint/SKILL.md': [
        '## 6. Finish', '', '1. `/swift-harness:qa` when `sim_qa` is `changed`.', '2. `"$SG" sprint finish --gate <run id> --json`.', '',
      ].join('\n'),
      'skills/ship/SKILL.md': 'Run `/swift-harness:build`.\n',
      'skills/validate/SKILL.md': [
        '| Simulator QA | <verdict> |', '', 'Read `sim/report.json` keys `runID`, `verdict` and `steps`.',
        'Read `qa/report.json` keys `runID` and `rows[]`, each row\'s keys `requirement`, `layer`, `check` and `result`.',
      ].join('\n'),
      'skills/qa/SKILL.md': '`"$SG" qa run --json`\n',
    }
    assert.deepEqual(callerQAProblems(files, keys), [
      'skills/ship/SKILL.md never runs `/swift-harness:qa`',
      'skills/ship/SKILL.md never reads the preset\'s `sim_qa`',
      'skills/build/SKILL.md still prints `validate: not configured`',
      'the build\'s validate stage runs `/swift-harness:qa` before `qa run --final`',
      'the build\'s validate stage never prints `validate: sim_qa off`',
      'the build skill\'s completion step never links the after-merge step',
      'the build loop has no `## Validate stage` section',
      'the build loop never hands a plan\'s validation task the shared validation worker brief',
      'the sprint never runs `/swift-harness:qa` after `sprint finish`',
      'the sprint never prints `validate: sim_qa off`',
      'the qa skill never names `qa run --final`',
      'the validate skill never lists a skipped simulator QA under "Not run"',
      'the validate skill reads `sim/report.json` keys `steps`, which nothing writes',
      'the validate skill never reads `sim/report.json` keys `stepCount`',
      'the validate skill never reads row\'s keys `evidence`',
    ])
    assert.deepEqual(callerQAProblems({}, keys), [
      ...CALLERS.flatMap(name => [`${name} never runs \`/swift-harness:qa\``, `${name} never reads the preset's \`sim_qa\``]),
      'the build\'s validate stage never runs `swiftgate qa run --plan <slug> --final`',
      'the build\'s validate stage never runs `/swift-harness:qa`',
      'the build\'s validate stage never prints `validate: sim_qa off`',
      'the build skill\'s completion step never links the after-merge step',
      'the build loop has no `## Validate stage` section',
      'the build loop never hands a plan\'s validation task the shared validation worker brief',
      'the sprint never runs `/swift-harness:qa` after `sprint finish`',
      'the sprint never prints `validate: sim_qa off`',
      'the qa skill never names `qa run --final`',
      'the validate block has no "Simulator QA" row',
      'the validate skill never lists a skipped simulator QA under "Not run"',
      'the validate skill never reads `sim/report.json` keys',
      'the validate skill never reads `qa/report.json` keys',
      'the validate skill never reads row\'s keys',
    ])
  },

  'the run validation check names each missing step — catches a checker that passes anything'() {
    const files = {
      'skills/run/SKILL.md': [
        '## 6. Land the contract commit', '', 'Write the types.', '',
        '## 7. Import and build', '', '1. `"$SG" qa run --at-base --json`.', '2. `"$SG" qa adopt <worktree> --json`.', '',
        '## 8. Final', '', '1. `"$SG" qa run --after <task> --json`.', '',
      ].join('\n'),
      'skills/run/references/plan-shape.md': ['```markdown', '### demo-validation', '- Writes: .harness/qa/demo/, Tests/DemoTests.swift', '```'].join('\n'),
      'skills/qa/references/validation-worker.md': 'Write the checks under `.harness/qa/`, then commit them.\n',
      'skills/build/references/event-loop.md': '## After each merge\n\n`"$SG" qa run --json`.\n',
    }
    assert.deepEqual(runValidationProblems(files), [
      'the run skill runs `qa run --at-base` before `qa adopt` copies the checks it reads',
      'step 7 never runs `swiftgate qa run --after <task>` after a merge',
      'step 8 never runs `swiftgate qa run` over every merged row',
      'the run skill never keeps `flow` rows to `xcode` areas',
      'the contract step never names a check\'s identifiers',
      'the contract step never names a check\'s routes',
      'the contract step never names a check\'s storage keys',
      'the contract step never names a check\'s log lines',
      'the after-merge step never runs `swiftgate qa run --after <task>`',
      'the after-merge step never undoes a merge whose rows read red',
      'the validation task example writes `Tests/DemoTests.swift`, outside `.harness/qa/`',
      'the run skill never hands its validation task the shared validation worker brief',
      'step 7 never says the validation task commits nothing',
    ])
    assert.deepEqual(runValidationProblems({}), [
      'the run skill never runs `swiftgate qa adopt`',
      'the run skill never runs `swiftgate qa run --at-base`',
      'step 7 never runs `swiftgate qa run --after <task>` after a merge',
      'step 8 never runs `swiftgate qa run` over every merged row',
      'the run skill never keeps `flow` rows to `xcode` areas',
      'the contract step never names a check\'s identifiers',
      'the contract step never names a check\'s routes',
      'the contract step never names a check\'s storage keys',
      'the contract step never names a check\'s log lines',
      'the build loop has no `## After each merge` step',
      'the plan shape has no `### <slug>-validation` task example',
      'no validation worker brief',
      'the run skill never hands its validation task the shared validation worker brief',
      'step 7 never says the validation task commits nothing',
    ])
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
    assert.match(launch ?? '', /buildRun: "<run>"/, 'the build skill never hands its build run id to build-task.js')
    assert.match(launch ?? '', /pluginRoot: "\$\{CLAUDE_PLUGIN_ROOT\}"/, 'the build skill never hands the plugin under test to build-task.js')
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
        '    contextPack: "c", model: "opus", review: "gate", taskProof: "final", buildRun: "r" }',
        '})',
        '```',
      ].join('\n'),
    }), [
      'x.md:2: context-pack --role worker needs exactly one of --design, --spec-page',
      'x.md:3: context-pack --role worker needs exactly one of --design, --spec-page',
      'x.md:7: build-task Workflow call lacks planSurface',
      'x.md:7: build-task Workflow call lacks pluginRoot',
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
      ['a new dependency accessor is wired to its key for real', /accessor is wired for real, as `get \{ self\[Key\.self\] \}` and `set \{ self\[Key\.self\] = newValue \}`/],
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

  'the ship skill records a confirm a delegated session gives as --by delegate, never as the user — catches a delegate recorded on disk as the user answering'() {
    const text = readFileSync(join(root, 'skills/ship/SKILL.md'), 'utf8')
    const [page] = numberedSections(text, /^## \d+\. Spec page\b/)
    const pageText = (page?.lines ?? []).join(' ').replace(/\s+/g, ' ')
    assert.match(pageText, /session the user delegated to[^.]*not from the user[^.]*`<by>` is `delegate`/, 'the page step never records a delegated answer as `delegate`')
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

  'the decomposer returns validation rows in validation.json\'s shape beside its tasks, and the plan skill writes validation.json before plan-lint and names its rules — catches a design plan built with no checks after each merge'() {
    const contract = validationContract()
    assert.deepEqual(contract.tableFields, ['schemaVersion', 'rows', 'unitOnly'])
    assert.deepEqual(contract.rowFields.map(f => f.name), ['requirement', 'layer', 'check', 'runsAfter', 'writer', 'reason'])
    assert.equal(contract.ruleIDs.length, 5)
    assert.deepEqual(validationTableProblems(planValidationFiles(), contract), [])
    const { problems } = scanSkills(join(root, 'skills/plan'), help, root)
    assert.deepEqual(problems, [])
  },

  'the validation table check names a missing write, a write after plan-lint, a spec-page plan left silent, a missing rule, a wrong shape and an uncovered requirement — catches a check that passes anything'() {
    const contract = validationContract()
    const plan = [
      '### A spec-page plan', '', 'Confirm the page.', '',
      '## 5. Schedule, write the ledger, lint', '',
      '1. Lint:', '', '   ```bash', '   "$SG" plan-lint <slug> --json', '   ```', '',
      '2. Write `<plans>/<slug>/validation.json`.', '',
      '## 6. Set the index', '',
      'The rules: `plan-lint.validation-uncovered`.',
    ].join('\n')
    const stateFiles = ['# Plan state files', '', '## `validation.json`', '', '```json', '{"schemaVersion": 2, "rows": []}', '```'].join('\n')
    const reply = {
      tasks: [{ id: 'a', covers: ['req-one', 'req-two'] }],
      validation: { rows: [{ requirement: 'req-one', layer: 'unit', check: 'x', runsAfter: ['b'], writer: 'a', why: 'no' }], unitOnly: [] },
    }
    const agent = ['# Decomposer', '', '## Output contract', '', '```json', JSON.stringify(reply), '```', '', 'Fix `plan-lint.validation-uncovered`.'].join('\n')
    assert.deepEqual(validationTableProblems({ plan, stateFiles, agent }, contract), [
      'step 5 writes `validation.json` after `plan-lint` reads it',
      'the spec-page section never says a spec-page plan writes no `validation.json`',
      'the plan skill never names `plan-lint.validation-unknown-task`',
      'the plan skill never names `plan-lint.validation-state-without-flow`',
      'the plan skill never names `plan-lint.validation-flow-without-ios`',
      'the plan skill never names `plan-lint.validation-check-source-file`',
      'the reference\'s `validation.json` keys are rows, schemaVersion, not schemaVersion, rows, unitOnly',
      'the reference\'s `validation.json` has no `schemaVersion` 1',
      'the decomposer\'s req-one unit row has keys requirement, layer, check, runsAfter, writer, why, not requirement, layer, check, runsAfter, writer, reason',
      'the decomposer\'s req-one unit row has a layer outside acceptance, flow, state',
      'the decomposer\'s req-one unit row names `b`, which is no task in the reply',
      'the decomposer\'s example leaves req-two with no row and no unit-only reason',
      'the decomposer never adds a validation task when 2 or more tasks build UI',
      'the decomposer\'s fix round never names `plan-lint.validation-unknown-task`',
      'the decomposer\'s fix round never names `plan-lint.validation-state-without-flow`',
      'the decomposer\'s fix round never names `plan-lint.validation-flow-without-ios`',
      'the decomposer\'s fix round never names `plan-lint.validation-check-source-file`',
    ])
    assert.deepEqual(validationTableProblems({ plan: '', stateFiles: '', agent: '' }, contract).slice(0, 2), [
      'step 5 never writes `<plans>/<slug>/validation.json`',
      'the spec-page section never says a spec-page plan writes no `validation.json`',
    ])
  },

  'the plan skill\'s spec-page confirm line names every approver plan confirm takes, delegate included — catches a delegated session steered to confirm as the user'() {
    const text = readFileSync(join(root, 'skills/plan/SKILL.md'), 'utf8')
    const section = text.slice(text.indexOf('\n### A spec-page plan\n') + 1).split(/\n#{2,3} /)[0]
    const confirms = [...section.matchAll(/`[^`]*\bplan confirm\b[^`]* --by [^`]*`/g)].map(m => m[0])
    assert.ok(confirms.length > 0, 'the spec-page section never runs plan confirm --by')
    for (const line of confirms) assert.match(line, / --by user\|spec-quotes\|delegate /, line)
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

  'no skill, agent or workflow runs a bare rm or mv, and the ship and sprint skills tell a headless session how to delete or move a file — catches a session stalled on a user\'s interactive rm alias'() {
    const files = shellInstructionFiles()
    assert.ok(files.length > 20 && files.some(f => f.endsWith('build-task.js')), `the scan reads only ${files.length} files`)
    const found = files.flatMap(file => bareRemoveOrMove(readFileSync(file, 'utf8')).map(hit => `${relative(root, file)}:${hit}`))
    assert.deepEqual(found, [])
    for (const skill of ['ship', 'sprint']) {
      const prose = readFileSync(join(root, `skills/${skill}/SKILL.md`), 'utf8').replace(/\s+/g, ' ')
      assert.match(prose, /To delete or move a file, run `command rm -f` or `command mv -f`/, `the ${skill} skill`)
    }
  },

  'the bare rm and mv check names each bare command in a fence, a code span or a chain, and passes command, /bin and prose — catches a check that passes anything'() {
    const text = [
      'Run `rm -rf .harness` first.', '```', 'cd x && mv a b', 'rm c', '/bin/rm -f d', 'command mv -f e f',
      'echo $(rm g)', '```', 'Remove the file, then rm it by hand.', '`git worktree remove x`', '`swiftgate prove`',
    ].join('\n')
    assert.deepEqual(bareRemoveOrMove(text), [
      '1: rm -rf .harness', '3: cd x && mv a b', '4: rm c', '7: echo $(rm g)',
    ])
  },

  'the build loop\'s red-main section takes its baseline from the user\'s go on or from the surface\'s untested modules taken without asking — catches the loop dropping the baseline step 1 took on its own'() {
    const loop = readFileSync(join(root, 'skills/build/references/event-loop.md'), 'utf8')
    const section = (loop.split('\n## Conflict or red main\n')[1] ?? '').split('\n## ')[0].replace(/\s+/g, ' ')
    assert.match(section, /the user chose \*\*go on\*\*/)
    assert.match(section, /`coverage\.no-t1-tests`[^.]*surface[^.]*without asking/)
    assert.match(section, /every gating finding is one of the baseline's[^.]*GREEN/)
    assert.doesNotMatch(section, /The same set counts as GREEN/)
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

  'the build skill measures its green-main, merge and final gates from plan.json\'s surfaceCommit when the plan has one, and runs its old lines when it has none — catches a surfaced plan\'s main judged from origin/main'() {
    const files = buildSkillFiles()
    assert.deepEqual(buildGateBaseProblems(files), [])
    const sha = '0123456789abcdef0123456789abcdef01234567'
    const surfaced = buildGatesFor(files, { surfaceCommit: sha }).filter(gate => gate.file === 'skills/build/SKILL.md')
    assert.deepEqual(surfaced.map(gate => gate.kind), ['green-main', 'merge', 'final'])
    for (const gate of surfaced) {
      assert.equal(gate.words[gate.words.indexOf('--base') + 1], sha, `the ${gate.kind} gate: ${gate.words.join(' ')}`)
    }
    const plain = buildGatesFor(files, {})
    for (const [file, expected] of Object.entries(BUILD_GATE_LINES_WITHOUT_SURFACE)) {
      assert.deepEqual(plain.filter(gate => gate.file === file).map(gate => gate.words.join(' ')), expected, file)
    }
    const { problems } = scanSkills(join(root, 'skills/build'), help, root)
    assert.deepEqual(problems, [])
  },

  'the build gate base check names a surfaced line without its base, a changed old line, a base other than the surface, a missing names row and a green-main check before the plan read — catches a check that passes anything'() {
    const skill = [
      '| Name | Value |', '|---|---|', '| `<slug>` | the plan |', '',
      '## 1. Start', '', '1. `"$SG" check --tier <merge_gate>`; with a plan surface, `"$SG" check --tier <merge_gate> --base main`.',
      '2. Read `plan.json` for the plan surface.', '',
      '## 3. On each completion', '', '4. `"$SG" check --tier <mergeGate> --json` on main.', '',
      '## 4. Finish', '', '1. `"$SG" check --tier ready`; with a plan surface, `"$SG" check --tier ready --base <surfaceCommit>`.',
    ].join('\n')
    const loop = ['`"$SG" check --tier <mergeGate>` or `"$SG" check --tier <mergeGate> --base <surfaceCommit>`.',
      '```', '"$SG" check --tier ready <the --proof-base arguments it printed>', '```'].join('\n')
    assert.deepEqual(buildGateBaseProblems({ 'skills/build/SKILL.md': skill, 'skills/build/references/event-loop.md': loop }), [
      'skills/build/SKILL.md:7: the green-main gate measures from main, not <surfaceCommit>',
      'skills/build/SKILL.md: a plan without a surface runs ["check --tier <merge_gate>","check --tier <mergeGate> --json","check --tier ready"], not ["check --tier <merge_gate>","check --tier <mergeGate>","check --tier ready"]',
      'skills/build/SKILL.md:7: the green-main gate has no `--base <surfaceCommit>` form for a plan with a surface',
      'skills/build/SKILL.md:12: the merge gate has no `--base <surfaceCommit>` form for a plan with a surface',
      'skills/build/references/event-loop.md:3: the final gate has no `--base <surfaceCommit>` form for a plan with a surface',
      'no `<surfaceCommit>` row in the names table',
      'the green-main check runs before step 1 reads the plan surface from plan.json',
    ])
  },
  'the surface baseline check names a missing rule, a command without its placeholders, no halt for other findings, a silent report, a final gate that takes the baseline and an exact-baseline merge gate — catches a check that passes anything'() {
    const skill = [
      '## 1. Start', '', '4. Check main. A later merge gate passes when its gating findings are exactly the', '   baseline\'s.', '',
      '   With a plan surface, take every `coverage.no-t1-tests` for a module the surface commit added as the baseline without asking. The surface added the module when `git diff --name-only HEAD` lists files and `git ls-tree -r --name-only <surfaceCommit>^ -- <file>` lists none.', '',
      '## 4. Finish', '', '1. Run the ready gate.', '',
      '## Report', '', 'The ledger page link.', '',
      '## Rules', '',
    ].join('\n')
    assert.deepEqual(surfaceBaselineProblems(skill), [
      'the changed command `git diff --name-only HEAD` doesn\'t name both <surfaceCommit> and <file>',
      'step 1 never halts on another gating finding beside the surface\'s',
      'the report never names a baseline taken without asking',
      'the final gate never says it takes no baseline',
      'a merge gate passes only on exactly the baseline, so a task that clears 1 of its findings reads as red',
    ])
    assert.deepEqual(surfaceBaselineProblems('## 1. Start\n\n4. Not GREEN: halt.\n'), [
      'step 1 takes no baseline without asking for a surface\'s untested new modules',
      'step 1 never halts on another gating finding beside the surface\'s',
      'the report never names a baseline taken without asking',
      'the final gate never says it takes no baseline',
    ])
    const reflowed = skill.replace('1. Run the ready gate.', '1. Run the ready gate. This gate takes no\n   baseline.')
    assert.ok(!surfaceBaselineProblems(reflowed).includes('the final gate never says it takes no baseline'))
  },

  'the qa, build, sprint and run skills warm the swiftgate binary in the foreground before step 1, at the Bash tool\'s 600000 ms timeout, and keep every call out of the background — catches a cold shim build that a headless session kills with no verdict'() {
    for (const skill of WARMED_SKILLS) {
      assert.deepEqual(warmUpProblems(readFileSync(join(root, `skills/${skill}/SKILL.md`), 'utf8')), [], `the ${skill} skill`)
    }
    const qa = h2Section(readFileSync(join(root, 'skills/qa/SKILL.md'), 'utf8'), 'Foreground work')
    assert.match(qa, /`qa run`/, 'the qa skill\'s foreground rule never names `qa run`')
    assert.match(qa, /`sim /, 'the qa skill\'s foreground rule never names the `sim` commands')
  },

  'the warm-up check names a missing section, one after step 1, and a missing warm-up, timeout and background rule — catches a check that passes anything'() {
    assert.deepEqual(warmUpProblems('## 1. Run\n\n`"$SG" qa run --json`\n'), ['no `## Foreground work` section'])
    assert.deepEqual(warmUpProblems('## 1. Run\n\nText.\n\n## Foreground work\n\nRun it.\n'), [
      '`## Foreground work` comes after step 1',
      '`## Foreground work` never warms the binary with `"$SG" --version`',
      '`## Foreground work` never sets the Bash timeout to 600000',
      '`## Foreground work` never rules out `run_in_background`',
    ])
    const good = '## Foreground work\n\nFirst `"$SG" --version` with `timeout` 600000; never `run_in_background`.\n\n## 1. Run\n'
    assert.deepEqual(warmUpProblems(good), [])
  },
}

if (isMain) {
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
}
