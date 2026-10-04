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
// which drops its gate reports; and an area command prefixed with a package install, which costs
// every slice the install that worktree creation already ran. Its phase spans are checked with the other skills' telemetry
// calls.
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
