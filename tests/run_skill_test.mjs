// Checks the brownfield run skill, its explorer agent and the bootstrap skill's brownfield branch
// against what a one-shot run needs, and parses the plan shape's example through the real
// `plan import` in a temp clone.
// Run: node tests/run_skill_test.mjs
// Regressions caught: an approval step or a question to the user creeping into a run that must
// take 0 human input; a commit that skips the repository's git hooks; an explorer on a model alias
// instead of a pinned id, or without its deadline and word cap; a run that never fixes a failing
// guess, never imports its plan, never runs `final` or never reports; a span seam that calls a
// command before it exists, or names a phase the CLI doesn't know; and a plan shape whose example
// `plan import` rejects.
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

// The `<!-- span: start|end <phase> -->` markers where the run viewer's span calls go.
const SPAN_MARKER = /<!-- span: (start|end) ([a-z-]+) -->/g

/** Problems with a skill's span seam: unknown phases, unbalanced markers, or a live span call. */
export function spanSeamProblems(text, phases) {
  const problems = []
  const open = new Map()
  for (const match of text.matchAll(SPAN_MARKER)) {
    const [, edge, phase] = match
    if (!phases.includes(phase)) problems.push(`span phase \`${phase}\` is not one the CLI records (${phases.join(', ')})`)
    open.set(phase, (open.get(phase) ?? 0) + (edge === 'start' ? 1 : -1))
    if (open.get(phase) < 0) problems.push(`span \`${phase}\` ends before it starts`)
  }
  for (const [phase, depth] of open) if (depth > 0) problems.push(`span \`${phase}\` starts and never ends`)
  for (const { line, words } of extractInvocations(text)) {
    if (words[0] === 'events' && words[1] === 'span') problems.push(`line ${line} calls \`events span\` before the run viewer wires it`)
  }
  return problems
}

/** The phases `events span start --help` lists after `The phase:`. */
function cliSpanPhases(binary, cwd) {
  const help = execFileSync(binary, ['events', 'span', 'start', '--help'], {
    encoding: 'utf8', cwd, env: { ...process.env, LLVM_PROFILE_FILE: join(cwd, 'help-%p.profraw') },
  })
  const listed = /The phase:([^.]*)\./.exec(help.replace(/\s+/g, ' '))
  assert.ok(listed, `events span start --help lists no phases:\n${help}`)
  return listed[1].split(/,| or /).map(s => s.trim()).filter(Boolean)
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

const tests = {
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

  'the run skill marks each run phase for the span calls without calling them, using only phases the CLI records — catches a seam that calls a stub or names an unknown phase'() {
    const binary = swiftgateBinary()
    assert.ok(binary, 'no swiftgate binary: build gate/ (swift build) or set SWIFTGATE_BIN')
    const phases = withTemp('run-skill-help-', dir => cliSpanPhases(binary, dir))
    const skill = read('skills/run/SKILL.md')
    assert.deepEqual(spanSeamProblems(skill, phases), [])
    const marked = new Set([...skill.matchAll(SPAN_MARKER)].map(m => m[2]))
    for (const phase of ['spec-read', 'discover', 'explore', 'plan', 'contract', 'final']) {
      assert.ok(marked.has(phase), `no span seam around the ${phase} phase`)
    }
  },

  'the span seam check names an unknown phase, an unbalanced marker and a live call — catches a checker that passes anything'() {
    const text = ['<!-- span: start plan -->', '<!-- span: end nap -->', '<!-- span: start final -->', '`"$SG" events span start --phase plan --build-run r`'].join('\n')
    assert.deepEqual(spanSeamProblems(text, ['plan', 'final']), [
      'span phase `nap` is not one the CLI records (plan, final)',
      'span `nap` ends before it starts',
      'span `plan` starts and never ends',
      'span `final` starts and never ends',
      'line 4 calls `events span` before the run viewer wires it',
    ])
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
