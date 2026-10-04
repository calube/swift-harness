// Replans an amended design the way the plan skill says to, against a scratch git repository with
// two real packages and the real swiftgate binary: a ledger with `done`, `pending` and
// `needs-replan` tasks, an amend that changes one id a `done` task covers and one a
// `needs-replan` task covers, then the skill's replan steps up to plan-lint.
// Run: node tests/plan_replan_test.mjs   (SWIFTGATE_BIN=plugin/bin/swiftgate to use the shim)
// Regressions caught: /plan halting on a ledger an amend left behind, so needs-replan tasks and
// fixes for done work have no path; a replan that rewrites a done task; a replanned plan that
// plan-lint still reads at the old designSha; a done task's renamed test id, or a module's own
// test target, keeping a replan red; and a skill step whose command no longer runs.
import assert from 'node:assert/strict'
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { execFileSync, spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gitPath } from './developer_tools.mjs'
import { removeTempTree } from './temp_tree.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const planSkill = () => readFileSync(join(root, 'skills/plan/SKILL.md'), 'utf8')

function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(root, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(root, 'bin/swiftgate')
}

// The text under `heading` (an exact heading line), up to the next heading of the same or a
// higher level.
function section(markdown, heading) {
  const lines = markdown.split('\n')
  const start = lines.indexOf(heading)
  assert.ok(start >= 0, `the plan skill has no heading ${JSON.stringify(heading)}`)
  const level = heading.match(/^#+/)[0].length
  const end = lines.findIndex((line, i) => i > start && /^#+ /.test(line) && line.match(/^#+/)[0].length <= level)
  return lines.slice(start, end < 0 ? lines.length : end).join('\n')
}

// Every `"$SG" …` command in `text`: fenced lines and inline code spans, whitespace-normalised.
function commands(text) {
  const found = []
  let fenced = false
  for (const line of text.split('\n')) {
    if (/^\s*```/.test(line)) {
      fenced = !fenced
      continue
    }
    if (fenced) {
      const at = line.indexOf('"$SG" ')
      if (at >= 0) found.push(line.slice(at + 6).trim().replace(/\s+/g, ' '))
    } else {
      for (const m of line.matchAll(/`"\$SG" ([^`]+)`/g)) found.push(m[1].trim().replace(/\s+/g, ' '))
    }
  }
  return found
}

function the(text, prefix, where) {
  const match = commands(text).find(c => c.startsWith(prefix))
  assert.ok(match, `${where} runs no \`${prefix}\``)
  return match
}

// The skill's mode table as [ledger condition, mode] rows.
function modeRows() {
  const table = section(planSkill(), '### Fresh plan or replan')
  return table.split('\n').filter(l => /^\|/.test(l) && !/^\|[-\s|]+\|$/.test(l)).slice(1)
    .map(l => l.split('|').slice(1, -1).map(c => c.trim()))
}

// The mode of the first row whose condition starts with `condition`.
function modeWhere(condition) {
  const row = modeRows().find(([ledger]) => ledger.startsWith(condition))
  assert.ok(row, `the mode table has no row starting ${JSON.stringify(condition)}`)
  return row[1]
}

const SLUG = '2026-09-27-order-queue'
const DOC = 'docs/designs/order-queue.md'
const EV = 'docs/designs/order-queue.evidence'
const SESSION = 'session-plan'

const design = ({ coreText, uiText, coreTest = 'test-queue-core-replays-in-order' }) => `---
status: approved
---
# Order queue

## Requirements

- req-queue-client: the client interface names every queue call
- req-queue-core: ${coreText}
- req-queue-ui: ${uiText}

## Test plan by tier

- test-queue-client-rejects-empty: an empty order is rejected — tier T1
- ${coreTest}: queued orders replay in submit order — tier T1
- test-queue-ui-shows-pending: the view lists pending orders — tier T1
`

const task = (id, fields) => ({
  id, deps: [], gate: 'fast', estLines: 120, status: 'pending', worktree: `../scratch-${SLUG}-${id}`, model: 'sonnet', ...fields,
})

function withRepo(body) {
  const dir = mkdtempSync(join(tmpdir(), 'plan-replan-'))
  const git = (...args) => execFileSync(gitPath, ['-c', 'user.name=t', '-c', 'user.email=t@example.com', ...args], { cwd: dir, stdio: 'pipe', encoding: 'utf8' })
  cpSync(join(root, 'gate/Fixtures/module-graph/repo'), dir, { recursive: true })
  writeFileSync(join(dir, '.gitignore'), '.harness/\n')
  git('init', '-q', '-b', 'main')
  const binary = swiftgateBinary()
  const run = (argv) => {
    const result = spawnSync(binary, argv, {
      cwd: dir,
      encoding: 'utf8',
      env: { ...process.env, LLVM_PROFILE_FILE: join(dir, '.git', 'profile-%p.profraw'), SWIFTGATE_HARNESS_ROOT: root },
      timeout: 55_000,
    })
    assert.equal(result.error, undefined, `${argv.join(' ')}: ${result.error}`)
    let json = null
    try {
      json = JSON.parse(result.stdout)
    } catch {}
    return { status: result.status, json, stdout: result.stdout, text: `${argv.join(' ')}\n${result.stdout}${result.stderr}` }
  }
  // A skill command with its placeholders filled.
  const skill = (command, values) => run(command.split(' ').map(w => w.replace(/<([^>]+)>/g, (all, name) => {
    assert.ok(name in values, `\`${command}\`: no value for ${all}`)
    return values[name]
  })))
  const plans = join(dir, '.git', 'swift-harness', 'plans', SLUG)
  const readJSON = path => JSON.parse(readFileSync(path, 'utf8'))
  const writeJSON = (path, value) => {
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, JSON.stringify(value, null, 2) + '\n')
  }
  const commitDesign = (text, message) => {
    mkdirSync(join(dir, 'docs/designs'), { recursive: true })
    writeFileSync(join(dir, DOC), text)
    git('add', '-A')
    git('commit', '-q', '-m', message)
    const diff = run(['design-diff', `HEAD:${DOC}`, DOC, '--json'])
    assert.equal(diff.status, 0, diff.text)
    return diff.json.oldSha
  }
  try {
    return body({ dir, run, skill, plans, readJSON, writeJSON, commitDesign })
  } finally {
    removeTempTree(dir)
  }
}

// Schedules and writes a draft ledger, then lints the plan, with the skill's own step-5 commands.
function scheduleAndLint({ dir, skill, plans, readJSON, writeJSON }, tasks, resume) {
  const step5 = section(planSkill(), '## 5. Schedule, write the ledger, lint')
  const draftPath = join(dir, '.harness/plan-draft', SLUG, 'ledger.json')
  const draft = { schemaVersion: 1, resume, maxParallel: 3, tasks, waves: [] }
  writeJSON(draftPath, draft)
  const scheduled = skill(the(step5, 'plan-schedule', 'step 5'), { slug: SLUG })
  assert.equal(scheduled.status, 0, scheduled.text)
  draft.waves = scheduled.json.waves
  writeJSON(draftPath, draft)
  writeFileSync(join(plans, 'ledger.json'), readFileSync(draftPath))
  return skill(the(step5, 'plan-lint', 'step 5'), { slug: SLUG })
}

const tests = {
  'a ledger with done and needs-replan tasks replans instead of halting, and a build in flight still halts — catches /plan dead-ending after an amend'() {
    assert.match(modeWhere('has a `needs-replan` or `done` task, and none `in-progress`'), /replan/)
    assert.match(modeWhere('has an `in-progress` task'), /halt/)
    const rows = modeRows()
    assert.ok(rows.findIndex(([l]) => l.includes('in-progress') && !l.includes('none')) < rows.findIndex(([, m]) => /replan/.test(m)),
      'the in-flight halt must be checked before replan')
  },

  'every replan.json key the plan skill writes is one the decomposer reads — catches the two sides of the replan input drifting apart'() {
    const reference = readFileSync(join(root, 'skills/plan/references/state-files.md'), 'utf8')
    const shape = section(reference, '## `replan.json`').split('```json')[1].split('```')[0]
    const keys = Object.keys(JSON.parse(shape)).filter(k => k !== 'schemaVersion')
    assert.ok(keys.length >= 5, `replan.json documents only ${keys}`)
    const decomposer = section(readFileSync(join(root, 'agents/design-decomposer.md'), 'utf8'), '## Replan')
    for (const key of keys) assert.ok(decomposer.includes(`"${key}"`), `the decomposer's Replan section never names "${key}"`)
  },

  'an amended plan replans around its kept tasks and plan-lint is GREEN at the new designSha — catches a replan that edits done work or lints the old design'() {
    withRepo(ctx => {
      const { dir, run, skill, plans, readJSON, writeJSON, commitDesign } = ctx
      const v1 = commitDesign(design({ coreText: 'queued orders drain on reconnect', uiText: 'the view shows the queue' }), 'design')
      const claimed = run(['plan', 'claim', SLUG, '--session', SESSION, '--design', DOC, '--json'])
      assert.equal(claimed.status, 0, claimed.text)
      writeJSON(join(plans, 'plan.json'), {
        ...readJSON(join(plans, 'plan.json')), designSha: v1,
        approval: { decision: 'approve', designSha: v1, at: '2026-09-27T10:00:00Z' },
      })
      const first = scheduleAndLint(ctx, [
        task('queue-client', { writeSet: ['Packages/Orders/Sources/OrderQueueClient/'], tests: ['test-queue-client-rejects-empty'], covers: ['req-queue-client', 'test-queue-client-rejects-empty'] }),
        task('queue-core', { deps: ['queue-client'], writeSet: ['Packages/Orders/Sources/OrderQueueCore/'], tests: ['test-queue-core-replays-in-order'], covers: ['req-queue-core', 'test-queue-core-replays-in-order'] }),
        task('queue-ui', { deps: ['queue-core'], writeSet: ['Packages/Orders/Sources/OrderQueueUI/'], tests: ['test-queue-ui-shows-pending'], covers: ['req-queue-ui', 'test-queue-ui-shows-pending'] }),
      ], 'planned')
      assert.equal(first.status, 0, first.text)

      // The build finished two tasks; then an amend changed an id each of queue-core (done) and
      // queue-ui covers, re-approved, and paused queue-ui.
      const built = readJSON(join(plans, 'ledger.json'))
      for (const t of built.tasks) if (t.id !== 'queue-ui') Object.assign(t, { status: 'done', actualLines: 140, branch: `${SLUG}/${t.id}` })
      const v2 = commitDesign(design({ coreText: 'queued orders drain on reconnect in batches of 20', uiText: 'the view shows the queue and each batch' }), 'amend')
      const changedIds = ['req-queue-core', 'req-queue-ui']
      mkdirSync(join(dir, EV), { recursive: true })
      writeFileSync(join(dir, EV, 'amendments.jsonl'), JSON.stringify({
        title: 'queue drains in batches of 20', at: '2026-09-27T12:00:00Z', class: 'amend', fromSha: v1, toSha: v2, changedIds, newClaims: [], trigger: 'user request',
        approval: { decision: 'approve', designSha: v2, at: '2026-09-27T12:30:00Z' },
      }) + '\n')
      writeJSON(join(plans, 'plan.json'), {
        ...readJSON(join(plans, 'plan.json')), approval: { decision: 'approve', designSha: v2, at: '2026-09-27T12:30:00Z' }, clarifyChain: [],
      })
      for (const t of built.tasks) if (t.covers.some(id => changedIds.includes(id)) && t.status !== 'done') t.status = 'needs-replan'
      writeFileSync(join(plans, 'ledger.json'), JSON.stringify(built, null, 2) + '\n')

      // Before the replan, plan-lint still reads the plan at v1 and HEAD has moved.
      const stale = run(['plan-lint', SLUG, '--json'])
      assert.equal(stale.status, 1, stale.text)
      assert.ok(stale.json.findings.some(f => f.rule === 'plan-lint.design-moved'), stale.text)

      const replan = section(planSkill(), '### Replan')
      assert.match(replan, /replan\.json/)

      // Step 2 keeps <planned> and moves plan.json to <current>.
      const planned = readJSON(join(plans, 'plan.json')).designSha
      writeJSON(join(plans, 'plan.json'), { ...readJSON(join(plans, 'plan.json')), designSha: v2 })

      // Replan steps 1 and 2: changed ids from the amendment records, then the split.
      const records = readFileSync(join(dir, EV, 'amendments.jsonl'), 'utf8').trim().split('\n').map(l => JSON.parse(l))
      const changed = new Set()
      for (let sha = planned; sha !== v2;) {
        const record = records.find(r => r.fromSha === sha)
        assert.ok(record, `no amendment record from ${sha}`)
        record.changedIds.forEach(id => changed.add(id))
        sha = record.toSha
      }
      const fixed = built.tasks.filter(t => t.status !== 'needs-replan')
      const replace = built.tasks.filter(t => t.status === 'needs-replan')
      const fixIds = fixed.filter(t => t.status === 'done').flatMap(t => t.covers.filter(id => changed.has(id)).map(id => ({ id, doneTask: t.id })))
      assert.deepEqual(replace.map(t => t.id), ['queue-ui'])
      assert.deepEqual(fixIds, [{ id: 'req-queue-core', doneTask: 'queue-core' }])

      // The module graph the decomposer's pack reads comes from the skill's own command.
      const graphCommand = the(section(planSkill(), '### The decomposer'), 'module-graph', 'the decomposer step')
      const graph = skill(graphCommand, { slug: SLUG })
      assert.equal(graph.status, 0, graph.text)
      const graphFile = readFileSync(join(dir, '.harness/plan-draft', SLUG, 'module-graph.txt'), 'utf8')
      assert.match(graphFile, /^OrderQueueCore -> OrderQueueClient$/m)

      // The decomposer's reply: a replacement for queue-ui, and a fix task for the done queue-core.
      const reply = [
        task('queue-ui', { deps: ['queue-core-batch-drain'], writeSet: ['Packages/Orders/Sources/OrderQueueUI/'], tests: ['test-queue-ui-shows-pending'], covers: ['req-queue-ui', 'test-queue-ui-shows-pending'] }),
        task('queue-core-batch-drain', { deps: ['queue-core'], writeSet: ['Packages/Orders/Sources/OrderQueueCore/'], tests: ['test-queue-core-replays-in-order'], covers: ['req-queue-core', 'test-queue-core-replays-in-order'], model: 'opus' }),
      ]
      const fixedIds = new Set(fixed.map(t => t.id))
      assert.ok(reply.every(t => !fixedIds.has(t.id)), 'a reply task reuses a fixed task id')

      const linted = scheduleAndLint(ctx, [...fixed, ...reply], `replanned at ${v2}; 2 of 4 tasks done; next: build the next wave`)
      assert.equal(linted.status, 0, linted.text)
      assert.ok(!linted.json.findings.some(f => f.rule === 'plan-lint.design-moved'), linted.text)

      const ledger = readJSON(join(plans, 'ledger.json'))
      assert.deepEqual(ledger.tasks.slice(0, fixed.length), fixed, 'a kept task changed')
      assert.deepEqual(ledger.tasks.filter(t => t.status === 'done').map(t => t.id), ['queue-client', 'queue-core'])
      assert.equal(readJSON(join(plans, 'plan.json')).designSha, v2)
    })
  },

  'after an amend renames a test id a done task names, a fix task takes plan-lint GREEN, and the same rename on a pending task stays RED — catches a replan that can never pass (spec §8.4)'() {
    withRepo(ctx => {
      const { run, plans, readJSON, writeJSON, commitDesign } = ctx
      const text = { coreText: 'queued orders drain on reconnect', uiText: 'the view shows the queue' }
      const v1 = commitDesign(design(text), 'design')
      const claimed = run(['plan', 'claim', SLUG, '--session', SESSION, '--design', DOC, '--json'])
      assert.equal(claimed.status, 0, claimed.text)
      writeJSON(join(plans, 'plan.json'), {
        ...readJSON(join(plans, 'plan.json')), designSha: v1,
        approval: { decision: 'approve', designSha: v1, at: '2026-09-27T10:00:00Z' },
      })
      // Each task writes its module and its module's own test target, as the decomposer is told to.
      const planned = [
        task('queue-client', { writeSet: ['Packages/Orders/Sources/OrderQueueClient/'], tests: ['test-queue-client-rejects-empty'], covers: ['req-queue-client', 'test-queue-client-rejects-empty'] }),
        task('queue-core', { deps: ['queue-client'], writeSet: ['Packages/Orders/Sources/OrderQueueCore/', 'Packages/Orders/Tests/OrderQueueCoreTests/'], tests: ['test-queue-core-replays-in-order'], covers: ['req-queue-core', 'test-queue-core-replays-in-order'] }),
        task('queue-ui', { deps: ['queue-core'], writeSet: ['Packages/Orders/Sources/OrderQueueUI/'], tests: ['test-queue-ui-shows-pending'], covers: ['req-queue-ui', 'test-queue-ui-shows-pending'] }),
      ]
      const first = scheduleAndLint(ctx, planned, 'planned')
      assert.equal(first.status, 0, first.text)

      // queue-core is built, then an amend renames its test id and is re-approved.
      const renamed = 'test-queue-core-replays-in-submit-order'
      const v2 = commitDesign(design({ ...text, coreTest: renamed }), 'amend')
      writeJSON(join(plans, 'plan.json'), {
        ...readJSON(join(plans, 'plan.json')), designSha: v2,
        approval: { decision: 'approve', designSha: v2, at: '2026-09-27T12:30:00Z' }, clarifyChain: [],
      })
      const fix = task('queue-core-submit-order', { deps: ['queue-core'], writeSet: ['Packages/Orders/Sources/OrderQueueCore/', 'Packages/Orders/Tests/OrderQueueCoreTests/'], tests: [renamed], covers: [renamed] })
      const withCore = status => planned.map(t => t.id === 'queue-ui' ? t : { ...t, status, ...(status === 'done' ? { actualLines: 130, branch: `${SLUG}/${t.id}` } : {}) })

      const done = scheduleAndLint(ctx, [...withCore('done'), fix], `replanned at ${v2}; 2 of 4 tasks done`)
      assert.equal(done.status, 0, done.text)

      const pending = scheduleAndLint(ctx, [...withCore('pending'), fix], `replanned at ${v2}`)
      assert.equal(pending.status, 1, pending.text)
      assert.ok(pending.json.findings.some(f => f.rule === 'plan-lint.unknown-test' && f.file === 'queue-core'), pending.text)
    })
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
