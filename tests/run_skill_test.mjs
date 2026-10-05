// Checks the brownfield run skill, its explorer agent and the bootstrap skill's brownfield branch
// against what a one-shot run needs, and parses the plan shape's example through the real
// `plan import` in a temp clone.
// Run: node tests/run_skill_test.mjs
// Regressions caught: an approval step or a question to the user creeping into a run that must
// take 0 human input; a commit that skips the repository's git hooks; an explorer on a model alias
// instead of a pinned id, or without its deadline and word cap; a run that never fixes a failing
// guess, never imports its plan, never runs `final` or never reports; a stopped or abandoned
// build that skips `final` and `build finish`; a design conflict answered with stop where widening
// the task's write set would do; a contract import that leaves it pending; a plan shape whose
// example `plan import` rejects; and a plan checkout made or removed with raw `git worktree`,
// which drops its gate reports; an area command prefixed with a package install, which costs
// every slice the install that worktree creation already ran; a run with no clock for its early
// steps, a cutoff that halts and asks or skips `final`, and an owned build that loses its halt at
// the cutoff; a gate, `qa run` or cutoff timer sent to the background, which a headless run kills
// when its turn ends with only background Bash work left, unless `build gate-wait` holds the turn;
// gate JSON written to a shared `/tmp` path another run overwrites; a merge gate waited on with no
// deadline, or a stuck one that holds the next ready merge; merges that ignore `build next`'s
// queue; and a stall watch or slot rule that ignores the box and the validation task. Its phase
// spans are checked with the other skills' telemetry calls.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseFrontmatter } from './design_agents_test.mjs'
import { gitPath } from './developer_tools.mjs'
import { extractInvocations, markdownFiles, swiftgateBinary } from './skill_commands_test.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const read = path => readFileSync(join(root, path), 'utf8')
const buildSkillFiles = () =>
  Object.fromEntries(markdownFiles(join(root, 'skills/build')).map(path => [relative(root, path), readFileSync(path, 'utf8')]))
const runSkillFiles = () =>
  Object.fromEntries((existsSync(join(root, 'skills/run')) ? markdownFiles(join(root, 'skills/run')) : [])
    .map(path => [relative(root, path), readFileSync(path, 'utf8')]))

const EXPLORER = 'agents/brownfield-explorer.md'
const PINNED_EXPLORER_MODEL = 'claude-sonnet-5-5'

// Wording that hands a choice to the user. A run takes 0 human input, so none of it may appear.
const ASKS_THE_USER = [
  /AskUserQuestion/,
  /\bask(?:s|ing)? (?:the )?user\b(?! is never)/i,
  /\bconfirm with the user\b/i,
  /\bwait(?:s|ing)? for (?:the user|approval|an answer)\b/i,
  /\bapproval (?:step|stage|gate)\b(?! is never)/i,
]

/** Every way `files` ({relative path: markdown}) asks the user or skips git hooks, as `file:line: …`. */
export function oneShotProblems(files) {
  const problems = []
  for (const [file, text] of Object.entries(files)) {
    for (const [index, line] of text.split('\n').entries()) {
      const where = `${file}:${index + 1}`
      if (line.includes('--no-verify')) problems.push(`${where}: names --no-verify`)
      for (const pattern of ASKS_THE_USER) {
        const match = pattern.exec(line)
        if (match) problems.push(`${where}: asks the user (\`${match[0]}\`)`)
      }
    }
  }
  return problems
}

/** Every line of `files` that runs `git … worktree`, as `file:line`. The plan checkout's gate
 * reports outlive it only when `swiftgate run checkout` makes and removes it. */
export function rawWorktreeCalls(files) {
  const problems = []
  for (const [file, text] of Object.entries(files)) {
    for (const [index, line] of text.split('\n').entries()) {
      if (/\bgit\b(?:\s+-\S+(?:\s+[^\s`-]\S*)?)*\s+worktree\b/.test(line)) problems.push(`${file}:${index + 1}`)
    }
  }
  return problems
}

/** The `## <n>. …` section of `text` whose heading starts with `heading`, without the heading. */
function section(text, heading) {
  const start = text.indexOf(`\n## ${heading}`)
  if (start < 0) return null
  const body = text.slice(start + 1)
  const next = body.indexOf('\n## ', 1)
  return next < 0 ? body : body.slice(0, next)
}

/** Every way the run skill `text` lets a run end without `final` and `build finish`: a line that
 * sends a stopped or abandoned build straight to the report, or a final step that doesn't say
 * every run reaches it. */
export function finalSkips(text) {
  const problems = []
  for (const [index, line] of text.split('\n').entries()) {
    if (/\b(?:stop|abandon)/i.test(line) && /\bstep 9\b/.test(line) && !/\bstep 8\b/.test(line)) {
      problems.push(`line ${index + 1}: a stopped build goes to step 9 without step 8`)
    }
  }
  const final = section(text, '8. Final')
  if (!final) return [...problems, 'no `## 8. Final` step']
  if (!/\bevery run\b/i.test(final)) problems.push('`## 8. Final` doesn\'t say every run reaches it')
  if (!/\bstopped\b/.test(final)) problems.push('`## 8. Final` doesn\'t name a stopped build')
  if (!/\b(?:blocked|abandoned)\b/.test(final)) problems.push('`## 8. Final` doesn\'t name blocked or abandoned tasks')
  for (const call of ['check --tier final', 'build finish <slug>']) {
    if (!extractInvocations(final).some(inv => inv.words.join(' ').startsWith(call))) {
      problems.push(`\`## 8. Final\` never runs \`swiftgate ${call}\``)
    }
  }
  return problems
}

/** How the run skill `text` answers a design conflict, as problems: stop marked recommended, or no
 * recommended retry that widens the task's write set through `PLAN.md` and `plan import`. */
export function designConflictProblems(text) {
  const paragraphs = text.split(/\n(?=\s*- )/).filter(p => /\bdesign conflict\b/i.test(p))
  if (paragraphs.length === 0) return ['no step answers a design conflict']
  const problems = []
  for (const paragraph of paragraphs) {
    if (/\*\*stop\*\*\s*\(Recommended\)/i.test(paragraph)) problems.push('a design conflict recommends stop')
  }
  const answer = paragraphs.join('\n')
  if (!/\*\*retry[^*]*write set\*\*\s*\(Recommended\)/i.test(answer)) {
    problems.push('a design conflict never recommends a retry with a widened write set')
  }
  if (!/`- Writes:`/.test(answer)) problems.push('the retry never widens the task\'s `- Writes:` in PLAN.md')
  const calls = extractInvocations(answer).map(inv => inv.words.join(' '))
  for (const call of ['plan import <slug>', 'ledger set <slug> <task> pending', 'build resume']) {
    if (!calls.some(c => c.startsWith(call))) problems.push(`the retry never runs \`swiftgate ${call}\``)
  }
  return problems
}

/** The bullet of the run skill `text` that answers the time box's cutoff: from `**The time box`
 * to the next bullet at its indent. */
function cutoffBullet(text) {
  const start = text.indexOf('**The time box')
  if (start < 0) return null
  const lineStart = text.lastIndexOf('\n', start) + 1
  const indent = /^\s*/.exec(text.slice(lineStart))[0]
  const rest = text.slice(start)
  const next = rest.search(new RegExp(`\\n${indent}- `))
  return next < 0 ? rest : rest.slice(0, next)
}

/** The bullet of `text` that starts at `marker`, up to the next bullet at its indent. */
function bulletAt(text, marker) {
  const start = text.indexOf(marker)
  if (start < 0) return null
  const lineStart = text.lastIndexOf('\n', start) + 1
  const indent = /^\s*/.exec(text.slice(lineStart))[0]
  const rest = text.slice(start)
  const next = rest.search(new RegExp(`\\n${indent}- `))
  return next < 0 ? rest : rest.slice(0, next)
}

/** Every way `text` runs a validation worker's proven rows a second time at the merge base: no
 * word that the `--at-base` run takes them from the adopted `at-base-run.json`, that only a
 * byte-identical check is taken, or that a taken row names its run in `reusedFrom`. */
export function atBaseReuseProblems(text) {
  const prose = text.replace(/\s+/g, ' ')
  const problems = []
  if (!/`at-base-run\.json`/.test(prose)) problems.push('never takes rows from the adopted `at-base-run.json`')
  if (!/byte-identical/.test(prose)) problems.push('never limits reuse to a byte-identical check')
  if (!/`reusedFrom`/.test(prose)) problems.push('never says a taken row names its run in `reusedFrom`')
  return problems
}

/** Every way `text` lets a validation task's checks reach a merge with no red run behind them:
 * no `qa run --at-base` after `qa adopt`, an at-base run that reads as optional, or a task its
 * rows wait for that may merge before it. */
export function atBaseProblems(text) {
  const calls = extractInvocations(text)
  const adopt = calls.find(inv => inv.words.join(' ').startsWith('qa adopt'))
  if (!adopt) return ['never runs `swiftgate qa adopt`']
  const problems = []
  const atBase = calls.find(inv => inv.words[0] === 'qa' && inv.words[1] === 'run' && inv.words.includes('--at-base'))
  if (!atBase) problems.push('never runs `swiftgate qa run --at-base`')
  else if (atBase.line < adopt.line) problems.push('runs `qa run --at-base` before `qa adopt`')
  const prose = text.replace(/\s+/g, ' ')
  if (!/`--at-base` run is never skipped/.test(prose)) problems.push('never says the `--at-base` run is never skipped')
  if (!/no task[^.]*`Runs after`[^.]*merges before/.test(prose)) {
    problems.push('lets a task a row\'s `Runs after` names merge before the `--at-base` run')
  }
  return problems
}

/** Every way the `qa run --before-merge` step `text` lets a RED validation row land: no run on
 * the branch before `build merge`, no recorded `gate-red` halt, no fixer for the `flows-red`
 * refusal, or a merge kept on judgement. */
export function validationRedProblems(text) {
  if (!text) return ['no step runs `qa run --before-merge`']
  const problems = []
  const calls = extractInvocations(text).map(inv => inv.words.join(' '))
  if (!calls.some(call => call.startsWith('qa run --plan <slug> --after <task> --before-merge'))) {
    problems.push('never runs `swiftgate qa run --after <task> --before-merge`')
  }
  if (!calls.some(call => call.startsWith('build halt --run <run> --task <task> --reason gate-red'))) {
    problems.push('a RED `qa run --before-merge` records no `gate-red` halt')
  }
  if (!calls.some(call => call.startsWith('build resume --run <run> --task <task> --answer retry'))) {
    problems.push('the `gate-red` halt is never resumed with `retry`')
  }
  const prose = text.replace(/\s+/g, ' ')
  if (!/`flows-red`[^.]*fix worktree/.test(prose)) problems.push('never says `build merge` refuses `flows-red` and cuts the fix worktree')
  if (!/\bfixer\b/.test(prose)) problems.push('a RED `qa run --before-merge` queues no fixer')
  if (!/never merge on (?:your|its) own judgement/i.test(prose)) problems.push('never forbids merging on judgement')
  return problems
}

/** Every way the run skill `text` lets a run outgrow its time box: no clock for its early steps, a
 * cutoff that halts and asks or records its own halt, or one that skips `final`. */
export function timeBoxProblems(text) {
  const problems = []
  const named = extractInvocations(text).map(inv => inv.words.join(' '))
  if (!named.some(call => call.startsWith('run clock <slug>'))) problems.push('the run never reads `swiftgate run clock`')
  for (const deadline of ['exploreBy', 'planBy', 'contractBy']) {
    if (!text.includes(`\`${deadline}\``)) problems.push(`no step is held to \`${deadline}\``)
  }
  const bullet = cutoffBullet(text)
  if (!bullet) return [...problems, 'no `**The time box` bullet answers the cutoff']
  const calls = extractInvocations(bullet).map(inv => inv.words.join(' '))
  if (!calls.some(call => call.startsWith('build cutoff <slug> --session <session>'))) {
    problems.push('the cutoff never runs `swiftgate build cutoff`')
  }
  if (calls.some(call => call.startsWith('build halt'))) problems.push('the cutoff records a halt itself')
  if (/\(Recommended\)/.test(bullet) || /\bask/i.test(bullet)) problems.push('the cutoff offers a choice')
  if (!/\bstep 8\b/.test(bullet)) problems.push('the cutoff never goes on to step 8')
  return problems
}

// A gate or `qa run` call, through `$SG` or any path to the swiftgate binary.
const GATE_CALL = /(?:swiftgate|\$SG)"?\s+(?:check\s|qa\s+run\b)/
// The foreground watch of a gate running in the background.
const GATE_WAIT = /(?:swiftgate|\$SG)"?\s+build\s+gate-wait\b/
// Work sent to the background: the Bash tool's flag, or a shell `&` that isn't `&&` or `>&`.
const BACKGROUND = /run_in_background|(?:^|[^&>])&\s*(?:$|`|;)/m
// A sleep that times something, not the poll interval of a `while` loop such as the stall watch.
const SLEEP_TIMER = /(?<![\w/])(?<!while\s+)(?:\/bin\/)?sleep\s+(?:<|\d|\$)/
// A path in the machine-wide temp directory, which every run on the machine shares.
const SHARED_TMP = /(?:^|[\s`'"=(>])\/(?:private\/)?tmp\//

/** Each paragraph or list item of `text` with the line it starts on. */
function blocks(text) {
  const found = []
  let start = 0
  let lines = []
  for (const [index, line] of text.split('\n').entries()) {
    const opens = /^\s*(?:[-*]|\d+\.)\s/.test(line) || line.trim() === ''
    if (opens && lines.length) {
      found.push({ line: start + 1, text: lines.join('\n') })
      lines = []
    }
    if (line.trim() === '') continue
    if (!lines.length) start = index
    lines.push(line)
  }
  if (lines.length) found.push({ line: start + 1, text: lines.join('\n') })
  return found
}

/** Every way `files` ({relative path: markdown}) leaves a run's work to die with a headless
 * session or to clash with another run, as `file:line: …`: a gate or `qa run` in the background, a
 * background sleep timer unless `sleepTimers` is false, and a shared `/tmp` path. */
export function backgroundWorkProblems(files, { sleepTimers = true } = {}) {
  const problems = []
  for (const [file, text] of Object.entries(files)) {
    for (const block of blocks(text)) {
      const where = `${file}:${block.line}`
      const background = BACKGROUND.test(block.text)
      // A gate `build gate-wait` watches keeps the turn alive in the foreground until it ends.
      const watched = GATE_WAIT.test(block.text)
      if (background && GATE_CALL.test(block.text) && !watched) problems.push(`${where}: a gate or qa run in the background`)
      if (sleepTimers && background && SLEEP_TIMER.test(block.text)) problems.push(`${where}: a background sleep timer`)
      if (SHARED_TMP.test(block.text)) problems.push(`${where}: a shared /tmp path`)
    }
  }
  return problems
}

/** The Bash calls the trial's headless orchestrator sent to the background, from its captured
 * stream-json, each rendered as the skill line that would have asked for it. */
function capturedBackgroundCalls() {
  const transcript = join(root, '..', 'evals/results/2026-10-04-brownfield-ios-validation/run.jsonl')
  const rendered = {}
  for (const line of readFileSync(transcript, 'utf8').split('\n')) {
    if (!line.trim()) continue
    const event = JSON.parse(line)
    if (event.type !== 'assistant') continue
    for (const content of event.message.content ?? []) {
      if (content.type !== 'tool_use' || content.name !== 'Bash' || !content.input.run_in_background) continue
      rendered[`call-${Object.keys(rendered).length + 1}`] = `- \`${content.input.command.split('\n').join(' ')}\` with \`run_in_background\``
    }
  }
  return rendered
}

/** Each paragraph of `files` that launches an agent with the Agent tool without saying it runs in
 * the background with `run_in_background: true`, as `file:line: …`. A foreground worker or fixer
 * holds every merge and start until it returns. */
export function agentLaunchProblems(files) {
  const problems = []
  for (const [file, text] of Object.entries(files)) {
    const lines = text.split('\n')
    let start = 0
    for (let i = 0; i <= lines.length; i++) {
      if (i < lines.length && lines[i].trim() !== '') continue
      const paragraph = lines.slice(start, i).join(' ')
      if (/\blaunch/i.test(paragraph) && /\bAgent tool\b/.test(paragraph)) {
        if (!/run_in_background: true/.test(paragraph)) problems.push(`${file}:${start + 1}: an Agent launch with no run_in_background: true`)
        if (/Agent tool,? in the foreground/.test(paragraph)) problems.push(`${file}:${start + 1}: an Agent launch in the foreground`)
      }
      start = i + 1
    }
  }
  return problems
}

/** Every way `files` ({relative path: markdown}) lets a merge gate run with no deadline or hold
 * the merges behind it, as `…` lines: no `build gate-wait` watch of a background merge gate, a
 * `Monitor` wait, an action of the watch left unexplained, or an `overrun` that isn't stopped,
 * undone as a RED gate and followed by the next ready merge. */
export function gateWatchProblems(files) {
  const problems = []
  const named = calls(files)
  if (!named.some(call => /^build gate-wait <slug> --tier \S+ --output \S+/.test(call))) {
    problems.push('no gate is watched with `swiftgate build gate-wait --tier --output`')
  }
  for (const [file, text] of Object.entries(files)) {
    for (const block of blocks(text)) {
      if (/\bMonitor\b/.test(block.text)) problems.push(`${file}:${block.line}: waits with Monitor`)
      if (GATE_CALL.test(block.text) && GATE_WAIT.test(block.text) && !BACKGROUND.test(block.text)) {
        problems.push(`${file}:${block.line}: a watched gate launched in the foreground`)
      }
    }
  }
  const text = Object.values(files).join('\n')
  for (const action of ['read', 'wait', 'overrun', 'cutoff']) {
    if (!bulletAt(text, `- \`${action}\``)) problems.push(`no bullet says what \`${action}\` means`)
  }
  const overrun = bulletAt(text, '- `overrun`') ?? ''
  const overrunCalls = extractInvocations(overrun).map(inv => inv.words.join(' '))
  if (!/\bTaskStop\b/.test(overrun)) problems.push('an `overrun` gate is never stopped with TaskStop')
  if (!/\bRED\b/.test(overrun)) problems.push('an `overrun` gate is never treated as RED')
  if (!overrunCalls.some(call => /^build merge <slug> <task> --undo\b/.test(call))) problems.push('an `overrun` merge is never undone')
  if (!/`readyToMerge`/.test(overrun)) problems.push('an `overrun` never lands the next ready task first')
  const wait = (bulletAt(text, '- `wait`') ?? '').replace(/\s+/g, ' ')
  if (!/never end the turn/i.test(wait)) problems.push('a `wait` may end the turn and kill the gate')
  return problems
}

/** Every way the build loop `text` merges outside `build next`'s queue, or lets a checked return
 * or a missing validation task stall the slots. */
export function mergeQueueProblems(text) {
  const prose = text.replace(/\s+/g, ' ')
  const problems = []
  if (!/`readyToMerge`/.test(prose)) problems.push('never merges from `build next`\'s `readyToMerge`')
  if (!/`merging`[^.]*absent|absent[^.]*`merging`/.test(prose)) problems.push('never waits for `merging` to clear before the next merge')
  const validation = (section(text, 'Validation task') ?? '').replace(/\s+/g, ' ')
  if (!/ahead of every other ready task/.test(validation)) problems.push('never says `build next` starts the validation task first')
  if (!/holds? no (?:worker )?slot/.test(prose)) problems.push('never says a checked return waiting to merge holds no slot')
  const stall = (section(text, 'Stall watch') ?? '').replace(/\s+/g, ' ')
  if (!/`stallMin`[^.]*(?:cutoff|box)/.test(stall)) problems.push('the stall watch never scales with the time left in the box')
  return problems
}

/** Every `swiftgate` call in `files` as `path flags…` strings, for presence checks. */
function calls(files) {
  return Object.values(files).flatMap(text => extractInvocations(text).map(inv => inv.words.join(' ')))
}

function withTemp(prefix, body) {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  try {
    return body(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

/** The first fenced ```markdown block of `text`: the plan shape's worked example. */
function exampleBlock(text) {
  const match = /```markdown\n([\s\S]*?)\n```/.exec(text)
  assert.ok(match, 'the plan shape has no ```markdown example')
  return match[1]
}

/** `plan import` of `planText` in a fresh brownfield temp clone: {status, report}. */
function importPlan(planText) {
  const binary = swiftgateBinary()
  assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
  return withTemp('run-skill-import-', dir => {
    const env = {
      ...process.env, LLVM_PROFILE_FILE: join(dir, 'import-%p.profraw'),
      GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@example.com', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@example.com',
    }
    const run = (file, args) => execFileSync(file, args, { encoding: 'utf8', cwd: dir, env, stdio: ['ignore', 'pipe', 'pipe'] })
    run(gitPath, ['init', '-q', '-b', 'main'])
    writeFileSync(join(dir, 'README'), 'x\n')
    run(gitPath, ['add', '-A'])
    run(gitPath, ['commit', '-qm', 'init'])
    run(binary, ['discover', '--apply'])
    const plan = join(dir, '.git/swift-harness/plans/demo')
    mkdirSync(plan, { recursive: true })
    writeFileSync(join(plan, 'PLAN.md'), planText)
    const result = spawnSync(binary, ['plan', 'import', 'demo', '--json'], { encoding: 'utf8', cwd: dir, env })
    return { status: result.status, report: JSON.parse(result.stdout || '{}'), stderr: result.stderr }
  })
}

// A package install chained before another command: what worktree creation makes unnecessary.
const INSTALL_PREFIX = /\b(?:pnpm|npm|yarn|bun) (?:install|ci|i)\b[^\n`]*(?:&&|;)/

/** Each line of `files` (path to text) that chains a package install before another command. */
function installPrefixes(files) {
  return Object.entries(files).flatMap(([path, text]) =>
    text.split('\n').filter(line => INSTALL_PREFIX.test(line)).map(line => `${path}: ${line.trim()}`))
}

const tests = {
  'worktree creation installs node dependencies, so the run skill says never to prefix an area command with an install, and no skill, agent or workflow chains one — catches orchestrators and workers paying an install on every slice'() {
    const prose = read('skills/run/SKILL.md').split(/\s+/).join(' ')
    assert.ok(prose.includes('install each node area\'s dependencies once'), 'the run skill doesn\'t say worktree creation installs')
    assert.ok(prose.includes('Never prefix an area command with an install'), 'the run skill doesn\'t forbid install prefixes')
    const files = Object.fromEntries(['skills', 'agents', 'workflows']
      .filter(directory => existsSync(join(root, directory)))
      .flatMap(directory => markdownFiles(join(root, directory)))
      .map(path => [relative(root, path), readFileSync(path, 'utf8')]))
    assert.deepEqual(installPrefixes(files), [])
  },
  'the install-prefix check names a pnpm, npm ci and yarn install chained before a command — catches a checker that passes anything'() {
    const planted = {
      'a.md': 'Run `pnpm install --frozen-lockfile --prefer-offline && pnpm run build` in web.',
      'b.md': 'npm ci; npm test',
      'c.md': 'yarn install && yarn lint\nRun `pnpm run build` alone.',
    }
    assert.deepEqual(installPrefixes(planted), [
      'a.md: Run `pnpm install --frozen-lockfile --prefer-offline && pnpm run build` in web.',
      'b.md: npm ci; npm test',
      'c.md: yarn install && yarn lint',
    ])
  },
  'the run skill, its references, the explorer and the bootstrap skill never ask the user and never skip git hooks — catches an approval step in a one-shot run'() {
    const files = { ...runSkillFiles(), [EXPLORER]: read(EXPLORER) }
    assert.ok(Object.keys(files).includes('skills/run/SKILL.md'), 'no skills/run/SKILL.md')
    assert.ok(Object.keys(files).includes('skills/run/references/plan-shape.md'), 'no skills/run/references/plan-shape.md')
    assert.deepEqual(oneShotProblems(files), [])
    const bootstrap = read('skills/bootstrap/SKILL.md')
    const brownfield = bootstrap.split(/\n## /).find(section => /^Brownfield/i.test(section))
    assert.ok(brownfield, 'the bootstrap skill has no `## Brownfield` section')
    assert.deepEqual(oneShotProblems({ 'skills/bootstrap/SKILL.md#Brownfield': brownfield }), [])
    assert.ok(extractInvocations(brownfield).some(inv => inv.words.join(' ').startsWith('discover --apply')),
      'the bootstrap skill\'s brownfield branch never runs `discover --apply`')
  },

  'the one-shot check names a question to the user and a hook skip — catches a checker that passes anything'() {
    const problems = oneShotProblems({
      'x.md': ['Ask the user with `AskUserQuestion` which area to build.', 'Commit with `git commit --no-verify`.', 'Wait for approval.'].join('\n'),
    })
    assert.deepEqual(problems, [
      'x.md:1: asks the user (`AskUserQuestion`)',
      'x.md:1: asks the user (`Ask the user`)',
      'x.md:2: names --no-verify',
      'x.md:3: asks the user (`Wait for approval`)',
    ])
  },

  'the run skill runs each phase of a run: discover fixes, plan import, the brownfield build, final and the report — catches a phase dropped from the procedure'() {
    const named = calls(runSkillFiles())
    const has = prefix => named.some(call => call.startsWith(prefix))
    for (const prefix of [
      'discover --json', 'discover --apply --set', 'discover --apply --drop', 'events list --kind warmup.run',
      'plan import <slug>', 'build start <slug> --preset brownfield', 'check --tier slice', 'check --tier final --base <base>',
      'run report <slug>', 'allow',
    ]) assert.ok(has(prefix), `the run skill never runs \`swiftgate ${prefix}\``)
    const skill = read('skills/run/SKILL.md')
    assert.match(skill, /swift-harness:brownfield-explorer/, 'the run skill never launches the explorer agent')
    assert.match(skill, /3-minute soft/, 'the explorers have no soft deadline')
    assert.match(skill, /4-minute hard/, 'the explorers have no hard deadline')
    assert.match(skill, /## Assumptions/, 'the run skill never records its readings in PLAN.md\'s Assumptions')
    assert.match(skill, /<plan-branch>/, 'the run skill never names the plan branch its commits land on')
  },

  'every way a run can stop its build still runs final and build finish, then the report — catches a run that abandons a build skipping final'() {
    assert.deepEqual(finalSkips(read('skills/run/SKILL.md')), [])
  },

  'the final-skip check names a stopped build sent to the report and a conditional final step — catches a checker that passes anything'() {
    const skipping = [
      '## 7. Import and build', '',
      'Take the recommended option. An option that stops the build ends the run at step 9 with the report.', '',
      '## 8. Final', '',
      'When `build next` reports nothing to start and nothing running, run `"$SG" check --tier final --base <base> --json`,',
      'then `"$SG" build finish <slug> --session <session> --json`.', '',
      '## 9. Report', '',
    ].join('\n')
    assert.deepEqual(finalSkips(skipping), [
      'line 3: a stopped build goes to step 9 without step 8',
      '`## 8. Final` doesn\'t say every run reaches it',
      '`## 8. Final` doesn\'t name a stopped build',
      '`## 8. Final` doesn\'t name blocked or abandoned tasks',
    ])
  },

  'the run holds its early steps to the clock and decides the cutoff by rule, then runs final — catches the cutoff asking for input in a brownfield run, and final skipped after a cutoff'() {
    const skill = read('skills/run/SKILL.md')
    assert.deepEqual(timeBoxProblems(skill), [])
    assert.deepEqual(finalSkips(skill), [])
    assert.match(section(skill, '8. Final'), /\bcutoff\b/, '`## 8. Final` doesn\'t name a run its cutoff ended')
  },

  'the time-box check names a cutoff that halts and asks, records its own halt and skips final — catches a checker that passes anything'() {
    const asking = [
      '## 7. Import and build', '',
      '   - **The time box.** At the cutoff, halt and ask: **stop them now** (Recommended) or let them finish.',
      '     Record it with `"$SG" build halt --run <run> --reason budget`, then go to step 9.',
      '   - Stop at its step 4.',
    ].join('\n')
    assert.deepEqual(timeBoxProblems(asking), [
      'the run never reads `swiftgate run clock`',
      'no step is held to `exploreBy`',
      'no step is held to `planBy`',
      'no step is held to `contractBy`',
      'the cutoff never runs `swiftgate build cutoff`',
      'the cutoff records a halt itself',
      'the cutoff offers a choice',
      'the cutoff never goes on to step 8',
    ])
  },

  'the build skill\'s owned cutoff still halts and asks, with stop them now recommended — catches the owned cutoff behaviour changing'() {
    const loop = read('skills/build/references/event-loop.md')
    const budget = loop.slice(loop.indexOf('## Time budget'), loop.indexOf('## Final gate'))
    assert.match(budget, /Tasks running: halt\. Options: \*\*stop them now\*\* \(Recommended\), or \*\*let them finish\*\*/)
    assert.match(read('skills/build/SKILL.md'), /a time-budget cutoff/)
    const calls = Object.values(buildSkillFiles()).flatMap(text => extractInvocations(text).map(inv => inv.words.join(' ')))
    assert.deepEqual(calls.filter(call => call.startsWith('build cutoff')), [], 'the owned build decides its cutoff by the brownfield rule')
  },

  'the run skill and the build loop it follows keep every gate and qa run in the foreground, set no background sleep timer and write no shared /tmp path — catches a headless run that exits mid-gate and kills it, and gate JSON another run overwrites'() {
    assert.deepEqual(backgroundWorkProblems(runSkillFiles()), [])
    // The owned build's budget timer stays: its session is interactive, and a run replaces it.
    assert.deepEqual(backgroundWorkProblems(buildSkillFiles(), { sleepTimers: false }), [])
    const skill = read('skills/run/SKILL.md')
    assert.match(skill, /\b600000\b/, 'the run skill never gives its foreground gates the Bash tool\'s longest timeout')
    assert.match(skill, /\| `<out>` \| `<plan-dir>\/[^`]+`/, 'the run skill never names a per-run directory under <plan-dir> for gate JSON')
    assert.ok(extractInvocations(cutoffBullet(skill) ?? '').some(inv => inv.words.join(' ').startsWith('run clock <slug>')),
      'the cutoff is never checked against `swiftgate run clock`')
  },

  'the background-work check names the trial orchestrator\'s background gates, qa run, cutoff timer and /tmp outputs, and passes its stall watches — catches a checker that passes anything'() {
    const captured = capturedBackgroundCalls()
    const problems = backgroundWorkProblems(captured)
    const flagged = kind => Object.keys(captured).filter(key => problems.includes(`${key}:1: ${kind}`))
    const text = key => captured[key]
    const gateCalls = Object.keys(captured).filter(key => /swiftgate (?:check|qa run)/.test(text(key)))
    assert.ok(gateCalls.length >= 4, `the transcript has ${gateCalls.length} background gate calls; it had the contract slices, qa run --at-base and a merge gate`)
    assert.deepEqual(flagged('a gate or qa run in the background'), gateCalls)
    const timers = Object.keys(captured).filter(key => /\/bin\/sleep 2234/.test(text(key)))
    assert.equal(timers.length, 1, 'the transcript has no background cutoff timer')
    assert.deepEqual(flagged('a background sleep timer'), timers)
    const tmp = Object.keys(captured).filter(key => /> \/tmp\/spec-/.test(text(key)))
    assert.ok(tmp.length >= 4, 'the transcript\'s gates no longer write /tmp/spec-*.json')
    assert.deepEqual(flagged('a shared /tmp path'), tmp)
    assert.deepEqual(backgroundWorkProblems({ 'x.md': '- Run `"$SG" check --tier merge --json &` and go on.\n- Then `"$SG" qa run --plan <slug> --json`.' }),
      ['x.md:1: a gate or qa run in the background'])
  },

  'the build loop and the run skill launch each merge gate in the background and watch it with build gate-wait, which stops an overrun as RED and lands the next ready task — catches the price-tracker orchestrator\'s 608 s foreground wait and 607 s Monitor on a hung merge gate'() {
    assert.deepEqual(gateWatchProblems(buildSkillFiles()), [])
    const run = runSkillFiles()
    assert.ok(calls(run).some(call => call.startsWith('build gate-wait <slug> --tier final --output <out>/final.json')),
      'the run skill never watches its final gate with build gate-wait')
    assert.ok(gateWatchProblems(run).every(problem => !/Monitor|foreground/.test(problem)), gateWatchProblems(run).join('\n'))
    assert.deepEqual(gateWatchProblems({ 'x.md': '- Run `"$SG" check --tier merge --json > o.json` and Monitor its output for GATE.' }), [
      'no gate is watched with `swiftgate build gate-wait --tier --output`',
      'x.md:1: waits with Monitor',
      'no bullet says what `read` means', 'no bullet says what `wait` means', 'no bullet says what `overrun` means', 'no bullet says what `cutoff` means',
      'an `overrun` gate is never stopped with TaskStop', 'an `overrun` gate is never treated as RED', 'an `overrun` merge is never undone',
      'an `overrun` never lands the next ready task first', 'a `wait` may end the turn and kill the gate',
    ])
    assert.deepEqual(backgroundWorkProblems({ 'x.md': '- Launch `"$SG" check --tier merge --json > o.json` with `run_in_background: true`, then watch it with `"$SG" build gate-wait <slug> --tier merge --output o.json`.' }), [])
  },

  'the build loop merges from build next\'s queue, frees the slots of returns waiting to merge, starts the validation task first and scales its stall watch to the box — catches client-live idle 1242 s behind a stuck merge and the send-money slot deadlock'() {
    assert.deepEqual(mergeQueueProblems(read('skills/build/references/event-loop.md')), [])
    assert.deepEqual(mergeQueueProblems('## Validation task\n\nStart it.\n\n## Stall watch\n\nWait 15 minutes.\n'), [
      'never merges from `build next`\'s `readyToMerge`', 'never waits for `merging` to clear before the next merge',
      'never says `build next` starts the validation task first', 'never says a checked return waiting to merge holds no slot',
      'the stall watch never scales with the time left in the box',
    ])
  },

  'every worker, fixer and explorer the run skill and the build loop launch is a background Agent call with run_in_background: true — catches a foreground fixer holding every merge and start for 481 s'() {
    assert.deepEqual(agentLaunchProblems(runSkillFiles()), [])
    assert.deepEqual(agentLaunchProblems(buildSkillFiles()), [])
    const loop = read('skills/build/references/event-loop.md')
    assert.match(section(loop, 'Conflict or red main') ?? '', /Launch `swift-harness:build-fixer` with the Agent tool in the background, passing\s+`run_in_background: true`/)
    assert.deepEqual(agentLaunchProblems({ 'x.md': 'Launch `swift-harness:build-fixer` with the Agent tool, in the foreground, and give it:\n\nThen go on.' }),
      ['x.md:1: an Agent launch with no run_in_background: true', 'x.md:1: an Agent launch in the foreground'])
  },

  'the run skill and the build loop run qa run --at-base after qa adopt, never skip it, and merge no task its rows wait for before it — catches checks adopted after their tasks merged with no red run'() {
    const skill = read('skills/run/SKILL.md')
    assert.deepEqual(atBaseProblems(skill), [], 'skills/run/SKILL.md')
    const loop = read('skills/build/references/event-loop.md')
    assert.deepEqual(atBaseProblems(section(loop, 'Validation task') ?? ''), [], 'event-loop.md#validation-task')
  },

  'the run skill and the build loop take the rows a validation worker proved from its at-base-run.json while each check is byte-identical, and the worker runs its prepared run last — catches every at-base row driven twice'() {
    assert.deepEqual(atBaseReuseProblems(read('skills/run/SKILL.md')), [], 'skills/run/SKILL.md')
    const loop = read('skills/build/references/event-loop.md')
    assert.deepEqual(atBaseReuseProblems(section(loop, 'Validation task') ?? ''), [], 'event-loop.md#validation-task')
    const worker = read('skills/qa/references/validation-worker.md').replace(/\s+/g, ' ')
    assert.match(worker, /Run it last, after your final edit/)
    assert.match(worker, /`at-base-run\.json`/)
  },

  'the reuse check names each missing part — catches a checker that passes anything'() {
    assert.deepEqual(atBaseReuseProblems('`"$SG" qa run --plan <slug> --at-base --json`'), [
      'never takes rows from the adopted `at-base-run.json`',
      'never limits reuse to a byte-identical check',
      'never says a taken row names its run in `reusedFrom`',
    ])
  },

  'the at-base check names a missing at-base run, one before the adopt, an optional one and an early merge — catches a checker that passes anything'() {
    assert.deepEqual(atBaseProblems('1. `"$SG" qa run --plan <slug> --at-base --json`\n2. `"$SG" qa adopt <worktree> --json`\n'), [
      'runs `qa run --at-base` before `qa adopt`',
      'never says the `--at-base` run is never skipped',
      'lets a task a row\'s `Runs after` names merge before the `--at-base` run',
    ])
    assert.deepEqual(atBaseProblems('`"$SG" qa adopt <worktree> --json`'), [
      'never runs `swiftgate qa run --at-base`',
      'never says the `--at-base` run is never skipped',
      'lets a task a row\'s `Runs after` names merge before the `--at-base` run',
    ])
    assert.deepEqual(atBaseProblems('no adopt'), ['never runs `swiftgate qa adopt`'])
  },

  'a RED qa run --before-merge records a gate-red halt and queues the fixer on the fix worktree build merge cut, with no override — catches screen rows run only after main moved'() {
    const skill = read('skills/run/SKILL.md')
    assert.deepEqual(validationRedProblems(bulletAt(skill, '**Validate before each merge**')), [], 'skills/run/SKILL.md')
    const loop = read('skills/build/references/event-loop.md')
    assert.deepEqual(validationRedProblems(section(loop, 'Before each merge')), [], 'event-loop.md#before-each-merge')
    const halts = section(loop, 'Recording halts') ?? ''
    assert.ok(halts.split('\n').some(line => line.startsWith('|') && line.includes('`qa run --before-merge`') && line.includes('`gate-red`')),
      'the halt table has no `gate-red` row for a RED `qa run --before-merge`')
  },

  'the validation-red check names each missing duty of the trial\'s rule, a run only after the merge — catches a checker that passes anything'() {
    const before = '- **Validate each merge**: `"$SG" qa run --plan <slug> --after <task> --json` in `<checkout>`. A RED\n  verdict counts as a red merge gate, wherever the loop or the cutoff handles one.\n'
    assert.deepEqual(validationRedProblems(bulletAt(before, '**Validate each merge**')), [
      'never runs `swiftgate qa run --after <task> --before-merge`',
      'a RED `qa run --before-merge` records no `gate-red` halt',
      'the `gate-red` halt is never resumed with `retry`',
      'never says `build merge` refuses `flows-red` and cuts the fix worktree',
      'a RED `qa run --before-merge` queues no fixer',
      'never forbids merging on judgement',
    ])
    assert.deepEqual(validationRedProblems(null), ['no step runs `qa run --before-merge`'])
  },

  'a brownfield design conflict recommends a retry with a widened write set, not stop — catches a brownfield write-set conflict recommending stop'() {
    assert.deepEqual(designConflictProblems(read('skills/run/SKILL.md')), [])
  },

  'the design-conflict check names the build skill\'s stop recommendation — catches a checker that passes anything'() {
    const loop = read('skills/build/references/event-loop.md')
    const block = loop.slice(loop.indexOf('`block`:'), loop.indexOf('`amend`:'))
    assert.match(block, /\*\*stop\*\* \(Recommended\)/, 'the build skill\'s block flow no longer recommends stop; pick another stop-recommending sample')
    const problems = designConflictProblems(`- A design conflict follows the build skill:\n${block.replace(/^\d+\. /gm, '  ')}`)
    assert.ok(problems.includes('a design conflict recommends stop'), problems.join('\n'))
    assert.ok(problems.includes('a design conflict never recommends a retry with a widened write set'), problems.join('\n'))
  },

  'the run skill imports its plan with the landed contract and its gate run — catches a contract left pending after import'() {
    const named = calls(runSkillFiles())
    assert.ok(named.some(call => call.startsWith('plan import <slug> --contract <contract-task> --contract-run <contract-run>')),
      'the run skill never imports with --contract and --contract-run')
    const contract = section(read('skills/run/SKILL.md'), '6. Land the contract commit')
    assert.ok(contract.indexOf('Commit on `<plan-branch>`') < contract.indexOf('check --tier slice'),
      'the contract is gated before it is committed, so its gate run names the base, not the contract commit')
  },

  'the run skill makes and removes the plan checkout through swiftgate, never raw git worktree — catches a checkout whose gate reports die with it'() {
    assert.deepEqual(rawWorktreeCalls(runSkillFiles()), [])
    const named = calls(runSkillFiles())
    for (const prefix of ['run checkout create <slug> --session <session>', 'run checkout remove <slug> --session <session>']) {
      assert.ok(named.some(call => call.startsWith(prefix)), `the run skill never runs \`swiftgate ${prefix}\``)
    }
  },

  'the raw worktree check names a git worktree call in any form — catches a checker that passes anything'() {
    assert.deepEqual(rawWorktreeCalls({
      'x.md': ['1. `git worktree add <checkout> <plan-branch>` from the user\'s checkout.', 'Then `git -C <common> worktree remove <checkout>`.', 'Read `git worktree list` to see it.'].join('\n'),
    }), ['x.md:1', 'x.md:2', 'x.md:3'])
  },

  'the explorer pins its model by id, stays read-only and returns 300 words or fewer once — catches an alias that drifts with the default model'() {
    const { fields, body } = parseFrontmatter(read(EXPLORER))
    assert.equal(fields.name, 'brownfield-explorer')
    assert.equal(fields.model, PINNED_EXPLORER_MODEL)
    const tools = fields.tools.split(',').map(s => s.trim())
    for (const tool of ['Edit', 'Write', 'NotebookEdit', 'Agent']) assert.ok(!tools.includes(tool), `the explorer may use ${tool}`)
    assert.match(body, /300 words/)
    assert.match(body, /return once/i)
    assert.match(body, /never (?:contact|message|ask) a human/i)
    for (const heading of ['Entry points', 'Files to change', 'Nearby tests', 'Working commands', 'Risks', 'Unknowns']) {
      assert.ok(body.includes(heading), `the explorer's return has no ${heading}`)
    }
  },

  'the plan shape\'s example imports through the real plan import with its assumptions — catches a documented shape the parser rejects'() {
    const shape = read('skills/run/references/plan-shape.md')
    const example = exampleBlock(shape)
    const { status, report, stderr } = importPlan(example)
    assert.equal(status, 0, `${report.message ?? ''}\n${stderr}`)
    assert.equal(report.status, 'imported')
    assert.ok(report.tasks >= 2, `the example has ${report.tasks} tasks; it shows a contract task and a dependent`)
    assert.ok(report.assumptions.length >= 1, 'the example carries no assumption')
    const broken = example.replace(/^- Writes:.*$/m, '- Writes:')
    assert.equal(importPlan(broken).report.status, 'invalid', 'an example without a write set still imports')
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
