// Checks the QA skill and its validation worker brief against the `swiftgate sim` and `qa`
// commands they drive.
// Run: node tests/qa_skill_test.mjs
// Regressions caught: a QA skill naming a `sim` or `qa` command or flag the CLI doesn't have; a
// flow that judges before `sim down` copies crash reports, or skips `sim down` on a failure; an
// `agent-device` call that drives a device without the run's `--udid` and `--session`, or opens or
// closes the app that `sim up` and `sim down` own; a verdict the skill states on its own; a flow
// kept without asking, past `max_flows`, or without the typed accessibility ids; prepared
// validation rows explored past instead of run first; a validation worker that writes outside its
// test files and `.harness/qa/<plan>/`, adds a contract name itself, or proves a red by hand rather
// than through `qa run --at-base --prepared-by`; a worker call cut at the 120 s tool timeout, a
// bare `ls` an alias turns into a wait on stdin, or a search of the whole disk for the record its
// prepared run wrote; a pull-to-refresh flow on a gesture that never refreshes the list; and a
// skill tuned to one app.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseFrontmatter } from './design_agents_test.mjs'
import { checkInvocations, extractInvocations, swiftgateBinary } from './skill_commands_test.mjs'
import { removeTempTree } from './temp_tree.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const SKILL = 'skills/qa/SKILL.md'
const WORKER = 'skills/qa/references/validation-worker.md'
const read = path => {
  assert.ok(existsSync(join(root, path)), `no ${path}`)
  return readFileSync(join(root, path), 'utf8')
}
const flat = text => text.replace(/\s+/g, ' ')

// The `## ` section whose heading starts with `title`, without its heading line.
function section(text, title) {
  const at = text.split('\n## ').find(part => part.startsWith(title))
  return at ? at.split('\n').slice(1).join('\n') : ''
}

// The first line of each `sim` step the skill runs, by subcommand.
function simStepLines(text) {
  const first = {}
  for (const { line, words } of extractInvocations(text)) {
    if (words[0] === 'sim' && words[1] && !(words[1] in first)) first[words[1]] = line
  }
  return first
}

/**
 * Where a QA skill's flow steps fall short: `sim up`, then `sim snap`, then `sim down`, then
 * `sim verify`, since `sim down` copies the crash reports `sim verify` names; `sim down` on every
 * path; prepared rows through `qa run` before the first device; and a verdict taken only from
 * what `sim verify` or `qa run` printed.
 */
export function flowOrderProblems(text) {
  const problems = []
  const steps = simStepLines(text)
  const order = ['up', 'snap', 'down', 'verify']
  for (const step of order) if (!(step in steps)) problems.push(`the skill never runs \`sim ${step}\``)
  const present = order.filter(step => step in steps)
  for (let i = 1; i < present.length; i++) {
    if (steps[present[i]] < steps[present[i - 1]]) {
      problems.push(`\`sim ${present[i]}\` comes before \`sim ${present[i - 1]}\``)
    }
  }
  const prose = flat(text)
  if (!/`sim down`[^.]*\bevery path\b/.test(prose)) problems.push('the skill never runs `sim down` on every path')
  const qaRun = extractInvocations(text).find(inv => inv.words[0] === 'qa' && inv.words[1] === 'run')
  if (!qaRun) problems.push('the skill never runs prepared validation rows with `qa run`')
  else if ('up' in steps && qaRun.line > steps.up) problems.push('the skill runs `qa run` after its first `sim up`')
  if (!/`validation\.json`/.test(prose)) problems.push('the skill never says when a plan has prepared rows (`validation.json`)')
  if (!/never states? a verdict[^.]*`sim verify`/i.test(prose)) problems.push('the skill never forbids a verdict `sim verify` didn\'t print')
  return problems
}

// Commands `sim up` and `sim down` own: the skill never runs them on the leased device.
const OWNED = ['open', 'close', 'boot', 'install', 'reinstall']

/**
 * Every `agent-device <command>` written in code (a fenced line or an inline span) that drives a
 * device: it must carry `--udid` and `--session`, and must not be a command `sim up` or `sim down`
 * owns. `help` reads no device.
 */
export function agentDeviceProblems(text) {
  const problems = []
  let inFence = false
  for (const [index, line] of text.split('\n').entries()) {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence
      continue
    }
    const segments = inFence ? [line] : line.split('`').filter((_, i) => i % 2 === 1)
    for (const segment of segments) {
      const match = /\bagent-device\s+([a-z][a-z-]*)/.exec(segment)
      if (!match || match[1] === 'help') continue
      const where = `${index + 1}: agent-device ${match[1]}`
      if (OWNED.includes(match[1])) problems.push(`${where} is owned by \`sim up\` or \`sim down\``)
      for (const flag of ['--udid', '--session']) if (!segment.includes(flag)) problems.push(`${where} lacks ${flag}`)
    }
  }
  return problems
}

// What a QA skill must say about its verdicts and about keeping a flow (design §8.1, §8.3).
const HANDOFFS = [
  [/`RED`[^.]*`\/swift-harness:tdd`/, 'a RED verdict never hands off to `/swift-harness:tdd`'],
  [/`BLOCKED`[^.]*`"\$SG" doctor`/, 'a BLOCKED verdict never runs `doctor`'],
  [/AskUserQuestion/, 'the skill never asks with `AskUserQuestion` which flows to keep'],
  [/never keeps? a flow[^.]*\bask/i, 'the skill never says it keeps no flow unasked'],
  [/`\[\[flows\]\]`/, 'a kept flow gets no `[[flows]]` entry'],
  [/`max_flows`[^.]*\bdrop\b/, 'the skill never asks which flow to drop at `max_flows`'],
  [/`AccessibilityID`/, 'a kept flow never reads the app\'s `AccessibilityID` module'],
  [/kept flow[^.]*`\/swift-harness:tdd`/i, 'a kept flow is not written test-first with `/swift-harness:tdd`'],
  [/`references\/validation-worker\.md`/, 'the skill never points a validation task at its brief'],
]

export function handoffProblems(text) {
  const prose = flat(text)
  return HANDOFFS.filter(([pattern]) => !pattern.test(prose)).map(([, message]) => message)
}

const PREPARED = '.harness/qa/<plan>/'

/**
 * Where a validation worker brief falls short of amendment §5: its write set holds the acceptance
 * test files its task names and `.harness/qa/<plan>/`, nothing else; a missing contract name is
 * reported, never added; it lints its flow files and records each check's failure reason; and the
 * gate, not the worker, confirms the red run with `qa run --at-base`.
 */
export function workerProblems(text) {
  const problems = []
  const writeSet = section(text, 'Write set')
  if (!writeSet) return ['the brief has no `## Write set` section']
  if (!writeSet.includes(`\`${PREPARED}\``)) problems.push(`the write set never names \`${PREPARED}\``)
  if (!/acceptance test files/.test(flat(writeSet))) problems.push('the write set never names the acceptance test files')
  for (const [, span] of writeSet.matchAll(/`([^`]+)`/g)) {
    if (!span.includes('/') || span.startsWith('.harness/qa/')) continue
    problems.push(`the write set names \`${span}\`, outside its test files and \`${PREPARED}\``)
  }
  const prose = flat(text)
  if (!/missing[^.]*name[^.]*\breport/i.test(prose) || !/never add/i.test(prose)) {
    problems.push('the brief never says a missing contract name is reported, not added')
  }
  if (!extractInvocations(text).some(inv => inv.words[0] === 'qa' && inv.words[1] === 'lint')) {
    problems.push('the brief never lints its flow files with `qa lint`')
  }
  if (!/failure reason/.test(prose)) problems.push('the brief never records each check\'s failure reason')
  if (!/`qa run --at-base`/.test(prose)) problems.push('the brief never says `qa run --at-base` confirms the red run')
  return problems
}

/**
 * Where a validation worker's red run falls short of the judge the gate uses: its
 * `## Record why each check fails now` section proves its prepared checks with 1
 * `qa run --at-base --prepared-by`, which leases the device, snaps each step and judges with
 * `sim verify` as the post-merge run does, and never drives a `sim` step or an `agent-device batch`
 * by hand. A worker that proved its reds by hand spent its own `sim up`s on a red that
 * `qa run --at-base` repeated minutes later.
 */
export function redRunProblems(text) {
  const section_ = section(text, 'Record why each check fails now')
  if (!section_) return ['the brief has no `## Record why each check fails now` section']
  const problems = []
  const invocations = extractInvocations(section_)
  const prepared = invocations.some(({ words }) =>
    words[0] === 'qa' && words[1] === 'run' && words.includes('--at-base') && words.includes('--prepared-by'))
  if (!prepared) problems.push('the red run never runs `qa run --at-base --prepared-by`')
  for (const step of Object.keys(simStepLines(section_))) problems.push(`the red run runs \`sim ${step}\` by hand`)
  if (/\bagent-device\s+batch\b[^\n]*--steps-file/.test(section_)) problems.push('the red run drives a raw `agent-device batch`')
  if (!/`guard\.validation-flow-by-hand`/.test(flat(section_))) {
    problems.push('the brief never says a raw batch of a prepared flow is denied')
  }
  return problems
}

/**
 * Where a validation worker brief lets a tool call stall the run: every `"$SG"` call runs in the
 * foreground with the Bash tool's `timeout` at 600000, since a call cut at the 120 s default goes
 * on in the background while the worker waits; the record a prepared run writes is read at the
 * `atBaseRecord` path `qa run` prints, never searched for; and no search leaves the worktree. A
 * worker that searched the whole disk for its own `at-base-run.json` held every ready merge, and
 * one whose bare `ls` ran an alias that read paths from the tool's never-closing stdin hung 120 s.
 */
export function toolCallProblems(text) {
  const problems = []
  const sentences = flat(text).split(/(?<=\.)\s/)
  const timed = sentences.find(s => /600000/.test(s) && /every `"\$SG"` call/.test(s))
  if (!timed) problems.push('the brief never gives every `"$SG"` call the 600000 `timeout`')
  else if (!/foreground/.test(timed)) problems.push('the brief never runs every `"$SG"` call in the foreground')
  if (!/`atBaseRecord`/.test(section(text, 'Record why each check fails now'))) {
    problems.push('the red run never reads its record at the `atBaseRecord` path `qa run` prints')
  }
  if (!sentences.some(s => /\bnever search/i.test(s) && /outside[^.]*worktree/.test(s))) {
    problems.push('the brief never forbids a search outside its worktree')
  }
  if (!sentences.some(s => /never a bare `ls`/.test(s) && /stdin/.test(s))) {
    problems.push('the brief never forbids a bare `ls`, which an alias can turn into a stdin read')
  }
  return problems
}

const REFRESH_FIXTURE = 'gate/Tests/Fixtures/AgentDevice/pull-to-refresh'
const GESTURES = 'docs/simulator-qa-flow-gestures.md'

// 1 captured refresh batch: its step 3, whether the list refreshed, and how far step 3 moved.
function capturedRefresh(name, fixture = REFRESH_FIXTURE) {
  const steps = JSON.parse(read(`${fixture}/${name}.steps.json`))
  const output = JSON.parse(read(`${fixture}/${name}.stdout`))
  const results = output.data?.results ?? output.error.details.partialResults
  const data = results.find(result => result.step === 3).data
  const [y1, y2] = data.from ? [data.from.y, data.to.y] : [data.y1, data.y2]
  return { step: steps[2], refreshed: output.success === true, distance: y2 - y1 }
}

/**
 * Where a text's pull-to-refresh recipe falls short of the captured runs: its step is the
 * `gesture` drag that refreshed, between 2 `id=` selectors; the distance it asks for is past
 * the short drag that didn't refresh and no more than the drag that did; and it says a `scroll`
 * never stands in. Two build trials left a refresh row red on a `scroll up`, and a fixer spent
 * 14 minutes finding out why.
 */
export function refreshProblems(text, { pass, short }) {
  const problems = []
  const prose = flat(text)
  const span = [...prose.matchAll(/`(\{"command": "gesture".*?\}\})`/g)].map(m => m[1])[0]
  if (!span) return ['no `gesture` step for pull to refresh']
  let step
  try {
    step = JSON.parse(span)
  } catch (error) {
    return [`the pull-to-refresh step isn't JSON: ${error.message}`]
  }
  if (step.input?.kind !== pass.step.input.kind) problems.push(`the step's kind is \`${step.input?.kind}\`, not the captured \`${pass.step.input.kind}\``)
  const keys = input => Object.keys(input ?? {}).sort().join(',')
  if (keys(step.input) !== keys(pass.step.input)) problems.push(`the step's keys are ${keys(step.input)}, not the captured ${keys(pass.step.input)}`)
  for (const key of ['source', 'destination']) {
    if (!/^id=/.test(step.input?.[key] ?? '')) problems.push(`the step's \`${key}\` is no \`id=\` selector`)
  }
  const least = /\bat least (\d+) pt\b/.exec(prose)
  if (!least) problems.push('the recipe names no distance in pt')
  else if (!(Number(least[1]) > short.distance && Number(least[1]) <= pass.distance)) {
    problems.push(`${least[1]} pt is not past the ${short.distance} pt drag that didn't refresh and within the ${pass.distance} pt one that did`)
  }
  if (!/`scroll`[^.]*\bnever\b[^.]*refresh/i.test(prose)) problems.push('the recipe never says a `scroll` never pulls to refresh')
  return problems
}

const SHORT_REFRESH_FIXTURE = 'gate/Tests/Fixtures/AgentDevice/pull-to-refresh-short'
const PLAN_SHAPE = 'skills/run/references/plan-shape.md'
// The modifier the captured short list pins its 1 pt drag target with.
const BOTTOM_ANCHOR = '.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: 1).accessibilityElement().accessibilityIdentifier('

/**
 * Where a text's scenario fake lets a flow read a call count, or answer faster than a gesture.
 * In the sixth price-tracker trial the fake added $1 per quotes call and answered at once, so 1
 * long drag loaded twice, the row read $64,002.00 for $64,001.00, and the fixer added a refresh
 * cooldown to the app to fit the fake.
 */
export function fakeShapeProblems(text, { latency = true } = {}) {
  const sentences = flat(text).split(/(?<=\.)\s+/)
  const problems = []
  if (latency && !sentences.some(s => /\bfake\b/i.test(s) && /\b300 ms\b/.test(s))) {
    problems.push('the fake answers with no fixed 300 ms delay')
  }
  if (!sentences.some(s => /\bfirst\b/i.test(s) && /\bevery later\b/i.test(s))) {
    problems.push('the fake\'s refresh change is not its first answer against every later one')
  }
  if (!sentences.some(s => /\bnever\b[^.]*\bcounts? (?:its )?calls\b/i.test(s))) {
    problems.push('never forbids a value that counts calls')
  }
  return problems
}

/**
 * Where a text's pull to refresh on a list too short to hold 2 ids 350 pt apart falls short of
 * the captured run: it pins the drag's end with the captured modifier, the contract adds it, and
 * the drag's destination is that pinned id. The fourth price-tracker trial left its refresh row
 * out because a 3-row list had no element that far below its top row.
 */
export function shortListProblems(text) {
  const problems = []
  const prose = flat(text)
  if (!prose.includes(BOTTOM_ANCHOR)) problems.push('no 1 pt id pinned to the bottom safe area with the captured modifier')
  if (!/\bcontract\b[^.]*\bbottom\b|\bbottom\b[^.]*\bcontract\b/i.test(prose)) problems.push('never says the contract adds the bottom-pinned id')
  if (!/"destination": "id=\\"<bottom[^"]*"/.test(prose)) problems.push('the drag never ends on the bottom-pinned id')
  return problems
}

// Words a generic skill never carries: every template preset but `default`, every captured spec
// page's title, and the example app's name.
function nonGenericWords() {
  const template = readFileSync(join(root, 'templates/swiftgate.toml'), 'utf8')
  const presets = [...template.matchAll(/^\[build\.presets\.([a-z0-9-]+)\]/gm)].map(m => m[1]).filter(name => name !== 'default')
  const fixtures = join(root, 'gate/Tests/Fixtures/spec-page')
  const titles = readdirSync(fixtures).filter(name => name.endsWith('.page.txt'))
    .map(name => /^# (.+)$/m.exec(readFileSync(join(fixtures, name), 'utf8'))[1])
  return [...presets, ...titles, 'SampleApp']
}

function realHelp() {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  const dir = mkdtempSync(join(tmpdir(), 'qa-skill-'))
  const cache = new Map()
  const help = path => {
    const key = path.join(' ')
    if (!cache.has(key)) {
      cache.set(key, execFileSync(binary, [...path, '--help'], {
        encoding: 'utf8',
        cwd: dir,
        env: { ...process.env, LLVM_PROFILE_FILE: join(dir, 'help-%p.profraw') },
      }))
    }
    return cache.get(key)
  }
  help.cleanup = () => removeTempTree(dir)
  return help
}

const skillFiles = () => ({ [SKILL]: read(SKILL), [WORKER]: read(WORKER) })

/**
 * Where a validation worker's repair mode could weaken a check or rewrite more than its row: the
 * `## Repair mode` section proves the rewrite red with a `--prepared-by --requirement` run, keeps
 * every `wait` and `is` step, changes only that requirement's files, reads the gestures doc, and
 * returns a `repaired:` or `no repair:` line.
 */
export function repairModeProblems(worker) {
  const part = section(worker, 'Repair mode').replace(/\s+/g, ' ')
  if (!part) return ['no `## Repair mode` section']
  const problems = []
  if (!part.includes('"$SG" qa run --plan <plan> --at-base --prepared-by <writer> --requirement <requirement> --output .harness/tmp/qa-repair.json')) {
    problems.push('no `qa run --at-base --prepared-by <writer> --requirement <requirement>` red run')
  }
  if (!/\bonly\b[^.]*requirement's (check )?files/.test(part)) problems.push('never limits the rewrite to the requirement\'s files')
  if (!/\bkeeps? every `wait` and `is` step\b/i.test(part)) problems.push('never keeps every `wait` and `is` step')
  if (!/simulator-qa-flow-gestures\.md/.test(part)) problems.push('never reads the gestures doc')
  if (!/a `wait` or `is` step/.test(part)) problems.push('never says the red at the base must fail on a `wait` or `is` step')
  if (!part.includes('repaired: <requirement> <path>: red: <message> (qa run <run id>)')) problems.push('no `repaired:` return line')
  if (!part.includes('no repair: <requirement>: <why>')) problems.push('no `no repair:` return line')
  return problems
}

const tests = {
  'the QA skill names every sim and qa command it drives, each with flags the real CLI has — catches a skill step drifting from the CLI'() {
    const help = realHelp()
    try {
      const invocations = Object.entries(skillFiles()).flatMap(([file, text]) =>
        extractInvocations(text).map(inv => ({ ...inv, file })))
      const { problems, resolved } = checkInvocations(invocations, help)
      assert.deepEqual(problems, [])
      const has = (path, flag) => resolved.some(r => r.path === path && (!flag || r.flags.includes(flag)))
      for (const [path, flag] of [['sim up', '--scenario'], ['sim snap', '--assert'], ['sim verify', '--json'], ['sim down', '--json'],
        ['qa run', '--plan'], ['qa lint'], ['doctor']]) {
        assert.ok(has(path, flag), `the QA skill never runs \`swiftgate ${path}${flag ? ` ${flag}` : ''}\``)
      }
    } finally {
      help.cleanup()
    }
  },

  'the QA skill runs prepared rows first, then up, snap, down on every path, then verify, and takes its verdict from sim verify — catches crash reports judged before sim down copies them'() {
    assert.deepEqual(flowOrderProblems(read(SKILL)), [])
  },

  'the flow order check names a missing step, verify before down, a skipped down, rows run after a device and a verdict of its own — catches a check that passes anything'() {
    const skill = [
      '1. `"$SG" sim up --json`', '2. `"$SG" sim snap "x" --assert "y"`', '3. `"$SG" sim verify`',
      '4. `"$SG" sim down`', '5. `"$SG" qa run --json`',
    ].join('\n')
    assert.deepEqual(flowOrderProblems(skill), [
      '`sim verify` comes before `sim down`',
      'the skill never runs `sim down` on every path',
      'the skill runs `qa run` after its first `sim up`',
      'the skill never says when a plan has prepared rows (`validation.json`)',
      'the skill never forbids a verdict `sim verify` didn\'t print',
    ])
    assert.deepEqual(flowOrderProblems('`"$SG" sim up`').slice(0, 3), [
      'the skill never runs `sim snap`', 'the skill never runs `sim down`', 'the skill never runs `sim verify`',
    ])
  },

  'every agent-device call in the QA skill carries the run\'s --udid and --session and leaves open and close to sim up and sim down — catches a call that drives another session\'s device'() {
    for (const [file, text] of Object.entries(skillFiles())) assert.deepEqual(agentDeviceProblems(text), [], file)
    assert.ok(/agent-device\s+snapshot[^`\n]*--udid/.test(read(SKILL)), 'the skill never shows an inspect call with --udid')
  },

  'the agent-device check names a call without --udid or --session and an open the skill runs itself — catches a check that passes anything'() {
    const text = [
      'Run `agent-device press id="a" --session <session>`.', '```', 'agent-device open app --udid <udid> --session <session>', '```',
      'See `agent-device help batch`.',
    ].join('\n')
    assert.deepEqual(agentDeviceProblems(text), ['1: agent-device press lacks --udid', '3: agent-device open is owned by `sim up` or `sim down`'])
  },

  'the QA skill hands RED to tdd and BLOCKED to doctor, and keeps a flow only when asked, test-first, under max_flows and on the typed ids — catches a flow kept unasked'() {
    assert.deepEqual(handoffProblems(read(SKILL)), [])
  },

  'the handoff check names each missing rule — catches a check that passes anything'() {
    const text = '`RED` hands off to `/swift-harness:tdd`. It asks with AskUserQuestion. It never keeps a flow without asking.'
    assert.deepEqual(handoffProblems(text), HANDOFFS.map(([, message]) => message)
      .filter(m => !/RED verdict|AskUserQuestion|unasked/.test(m)))
  },

  'the validation worker writes only its acceptance test files and .harness/qa/<plan>/, reports a missing contract name, lints and records each failure reason — catches a worker writing app code'() {
    assert.deepEqual(workerProblems(read(WORKER)), [])
  },

  'the worker check names a write set path outside the test files and .harness/qa, and each missing duty — catches a check that passes anything'() {
    const text = ['# Brief', '', '## Write set', '', '- `.harness/qa/<plan>/`', '- `Sources/App/Contract.swift`', '', '## Return', ''].join('\n')
    assert.deepEqual(workerProblems(text), [
      'the write set never names the acceptance test files',
      'the write set names `Sources/App/Contract.swift`, outside its test files and `.harness/qa/<plan>/`',
      'the brief never says a missing contract name is reported, not added',
      'the brief never lints its flow files with `qa lint`',
      'the brief never records each check\'s failure reason',
      'the brief never says `qa run --at-base` confirms the red run',
    ])
    assert.deepEqual(workerProblems('# Brief\n'), ['the brief has no `## Write set` section'])
  },

  'the validation worker proves its prepared checks red with 1 qa run --at-base --prepared-by and never by hand — catches a pre-merge red the gate\'s judge never saw'() {
    assert.deepEqual(redRunProblems(read(WORKER)), [])
  },

  'the validation worker runs every swiftgate call in the foreground at the 600000 timeout, reads its record at the printed atBaseRecord path, never runs a bare ls and never searches outside its worktree — catches a worker stalled on a disk-wide find or a stdin read'() {
    assert.deepEqual(toolCallProblems(read(WORKER)), [])
  },

  'the tool-call check names a missing timeout, a background call, an unread record path, a bare ls and a missing search ban — catches a check that passes anything'() {
    assert.deepEqual(toolCallProblems('# Brief\n\n## Record why each check fails now\n\nFind `at-base-run.json` and read it.\n'), [
      'the brief never gives every `"$SG"` call the 600000 `timeout`',
      'the red run never reads its record at the `atBaseRecord` path `qa run` prints',
      'the brief never forbids a search outside its worktree',
      'the brief never forbids a bare `ls`, which an alias can turn into a stdin read',
    ])
    assert.deepEqual(toolCallProblems('Run every `"$SG"` call with `timeout` at 600000.'), [
      'the brief never runs every `"$SG"` call in the foreground',
      'the red run never reads its record at the `atBaseRecord` path `qa run` prints',
      'the brief never forbids a search outside its worktree',
      'the brief never forbids a bare `ls`, which an alias can turn into a stdin read',
    ])
  },

  'the red-run check names a hand-driven sim run, a raw batch, a missing qa run and a missing section — catches a check that passes anything'() {
    const text = ['# Brief', '', '## Record why each check fails now', '', '```bash',
      '"$SG" sim up --json', 'agent-device batch --steps-file f --udid <udid> --session <session> --json',
      '"$SG" sim verify <runID> --json', '"$SG" qa run --plan <plan> --at-base --json', '```', '',
      'Record the failing step\'s number and message from the batch output.', '', '## Return', ''].join('\n')
    assert.deepEqual(redRunProblems(text), [
      'the red run never runs `qa run --at-base --prepared-by`',
      'the red run runs `sim up` by hand',
      'the red run runs `sim verify` by hand',
      'the red run drives a raw `agent-device batch`',
      'the brief never says a raw batch of a prepared flow is denied',
    ])
    assert.deepEqual(redRunProblems('# Brief\n'), ['the brief has no `## Record why each check fails now` section'])
  },

  'the QA skill is a plugin skill named qa whose text names no preset, captured page or example app — catches a skill tuned to one app'() {
    const { fields } = parseFrontmatter(read(SKILL))
    assert.equal(fields.name, 'qa')
    assert.match(fields.description ?? '', /\/swift-harness:qa/)
    const words = nonGenericWords()
    assert.ok(words.length >= 4, `the generic check reads only ${words.join(', ')}`)
    for (const [file, text] of Object.entries(skillFiles())) {
      const found = words.filter(word => new RegExp(`\\b${word.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'i').test(text))
      assert.deepEqual(found, [], `${file} names ${found.join(', ')}`)
    }
  },

  'the captured drag refreshes the list and the short drag and scroll up don\'t — catches a recipe built on a capture that shows nothing'() {
    const pass = capturedRefresh('drag')
    const short = capturedRefresh('drag-short')
    const scroll = capturedRefresh('scroll-up')
    assert.deepEqual([pass.refreshed, short.refreshed, scroll.refreshed], [true, false, false])
    assert.equal(pass.step.command, 'gesture')
    assert.ok(short.distance < pass.distance, `${short.distance} >= ${pass.distance}`)
  },

  'the validation worker and the flow gestures doc pull to refresh with the captured drag, never a scroll — catches a refresh row red on a gesture that never refreshes'() {
    const captured = { pass: capturedRefresh('drag'), short: capturedRefresh('drag-short') }
    assert.deepEqual(refreshProblems(read(WORKER), captured), [])
    assert.deepEqual(refreshProblems(read(GESTURES), captured), [])
    assert.match(flat(read('docs/simulator-qa-flows.md')), /\(simulator-qa-flow-gestures\.md\)/, 'the flows doc never links the gestures doc')
    assert.match(read('docs/index.md'), /\(simulator-qa-flow-gestures\.md\)/, 'the docs index never routes to the gestures doc')
  },

  'the refresh check names a scroll step, a short distance, a ref target and a missing scroll ban — catches a check that passes anything'() {
    const captured = { pass: capturedRefresh('drag'), short: capturedRefresh('drag-short') }
    const good = 'Pull to refresh: `{"command": "gesture", "input": {"kind": "drag", "source": "id=\\"a\\"", "destination": "id=\\"b\\""}}`, rows at least 350 pt apart. A `scroll` never pulls to refresh.'
    assert.deepEqual(refreshProblems(good, captured), [])
    assert.deepEqual(refreshProblems(good.replace('"command": "gesture"', '"command": "scroll"'), captured), ['no `gesture` step for pull to refresh'])
    assert.match(refreshProblems(good.replace('350 pt', '200 pt'), captured).join('\n'), /200 pt is not past/)
    assert.match(refreshProblems(good.replace('id=\\"a\\"', '@e3'), captured).join('\n'), /`source` is no `id=`/)
    assert.match(refreshProblems(good.replace('"kind": "drag"', '"kind": "pan"'), captured).join('\n'), /kind is `pan`/)
    assert.match(refreshProblems(good.replace('never', 'may'), captured).join('\n'), /never pulls to refresh/)
  },

  'on the captured 3-row list the drag from the top row to the 1 pt bottom-pinned id refreshes and the drag to the last row doesn\'t — catches a short-list recipe built on a capture that shows nothing'() {
    const pinned = capturedRefresh('drag-to-bottom', SHORT_REFRESH_FIXTURE)
    const lastRow = capturedRefresh('drag-to-last-row', SHORT_REFRESH_FIXTURE)
    assert.deepEqual([pinned.refreshed, lastRow.refreshed], [true, false])
    assert.ok(pinned.distance >= 350, `${pinned.distance} pt`)
    assert.ok(lastRow.distance < 350, `${lastRow.distance} pt`)
    assert.match(pinned.step.input.destination, /^id=/)
    assert.ok(read(`${SHORT_REFRESH_FIXTURE}/ShortRefreshProbe.swift`).includes(BOTTOM_ANCHOR), 'the probe pins its target another way')
  },

  'the validation worker, the gestures doc and the plan shape pull a short list to refresh onto a contract id pinned to the bottom safe area — catches a refresh row left out because no element sits 350 pt below the top row'() {
    for (const file of [WORKER, GESTURES, PLAN_SHAPE]) assert.deepEqual(shortListProblems(read(file)), [], file)
  },

  'the plan shape and the gestures doc give scenario fakes a fixed delay and a refresh value no call count moves, and the validation worker waits for it — catches a flow red on a long drag that loads twice, which a fixer then hides in the app'() {
    for (const file of [PLAN_SHAPE, GESTURES]) assert.deepEqual(fakeShapeProblems(read(file)), [], file)
    assert.deepEqual(fakeShapeProblems(read(WORKER), { latency: false }), [], WORKER)
  },

  'the fake shape check names a missing delay, refresh shape and count ban — catches a check that passes anything'() {
    const good = 'The fake answers after a fixed 300 ms. Its first load answers the seed and every later load the refreshed data, never a value that counts calls.'
    assert.deepEqual(fakeShapeProblems(good), [])
    assert.match(fakeShapeProblems(good.replace('300 ms', 'delay')).join('\n'), /300 ms/)
    assert.match(fakeShapeProblems(good.replace('every later', 'the next')).join('\n'), /first answer/)
    assert.match(fakeShapeProblems(good.replace('never', 'or')).join('\n'), /counts calls/)
    assert.deepEqual(fakeShapeProblems(good.replace('300 ms', 'delay'), { latency: false }), [])
  },

  'the short-list check names a missing modifier, contract and destination — catches a check that passes anything'() {
    const good = `The contract adds a bottom-pinned id: \`${BOTTOM_ANCHOR}"x.bottom")\`. The drag is \`{"command": "gesture", "input": {"kind": "drag", "source": "id=\\"<top row>\\"", "destination": "id=\\"<bottom id>\\""}}\`.`
    assert.deepEqual(shortListProblems(good), [])
    assert.match(shortListProblems(good.replace('safeAreaInset', 'overlay')).join('\n'), /captured modifier/)
    assert.match(shortListProblems(good.replace('contract', 'worker')).join('\n'), /contract adds/)
    assert.match(shortListProblems(good.replace('<bottom id>', '<lower element>')).join('\n'), /never ends on/)
  },

  'the validation worker\'s repair mode rewrites 1 requirement\'s flow, keeps its assertions and proves it red at the base again — catches a repair that weakens a check to pass'() {
    assert.deepEqual(repairModeProblems(read(WORKER)), [])
  },

  'the repair mode check names a missing run, scope, assertion rule, gestures doc, red reason and each return line — catches a check that passes anything'() {
    const good = `\n## Repair mode\n\nChange only the requirement's files. Keep every \`wait\` and \`is\` step. Read simulator-qa-flow-gestures.md. The red must fail on a \`wait\` or \`is\` step: \`"$SG" qa run --plan <plan> --at-base --prepared-by <writer> --requirement <requirement> --output .harness/tmp/qa-repair.json\`. Return \`repaired: <requirement> <path>: red: <message> (qa run <run id>)\` or \`no repair: <requirement>: <why>\`.\n`
    assert.deepEqual(repairModeProblems(good), [])
    assert.deepEqual(repairModeProblems(good.replace('## Repair mode', '## Other')), ['no `## Repair mode` section'])
    assert.match(repairModeProblems(good.replace(' --requirement <requirement>', '')).join('\n'), /--requirement/)
    assert.match(repairModeProblems(good.replace('Change only', 'Change')).join('\n'), /requirement's files/)
    assert.match(repairModeProblems(good.replace('Keep every', 'Keep a')).join('\n'), /every `wait` and `is`/)
    assert.match(repairModeProblems(good.replace('Read simulator-qa-flow-gestures.md', 'Read')).join('\n'), /gestures doc/)
    assert.match(repairModeProblems(good.replace('fail on a', 'fail at')).join('\n'), /must fail on/)
    assert.match(repairModeProblems(good.replace('repaired: <requirement>', 'done: <requirement>')).join('\n'), /`repaired:`/)
    assert.match(repairModeProblems(good.replace('no repair:', 'none:')).join('\n'), /`no repair:`/)
  },

  'the docs router sends a reader running simulator QA to the QA skill — catches a skill no doc reaches'() {
    const index = readFileSync(join(root, '..', 'docs/index.md'), 'utf8')
    const row = index.split('\n').find(line => line.startsWith('|') && line.includes('(../plugin/skills/qa/SKILL.md)'))
    assert.ok(row, 'docs/index.md has no row linking the QA skill')
    assert.match(row, /\/swift-harness:qa/)
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
