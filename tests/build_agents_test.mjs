// Checks agents/build-worker.md and agents/build-fixer.md against the build executor's agent
// contract. Run:
// node tests/build_agents_test.mjs
// Regressions caught: a worker pinned to one model when the workflow picks it per task; a fixer
// that isn't opus; a return example that drifts from `TaskReturn`'s keys, so `build check-return`
// rejects every return; an outcome the gate doesn't accept; a prompt that stops forbidding a
// command the PreToolUse guard denies, so the worker burns a turn on a denial; a worker that loses
// the `task-status.json` design-conflict report, test-first or the foreground rule; a fixer that
// may commit to `main` or merge.
//
// `checkBuildAgentText(fileName, text)` is exported so the checks run against edited copies too.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { AGENT_RULES, NATIVE_MODELS, jsonKeys, parseFrontmatter } from './design_agents_test.mjs'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const domainSource = relative => readFileSync(join(root, 'gate/Sources/SwiftGateDomain', relative), 'utf8')
const agentText = stem => readFileSync(join(root, 'agents', `${stem}.md`), 'utf8')

/** The `case` names of the `CodingKeys` enum inside `extension <type>: Codable`, raw values applied. */
export function codingKeys(swiftSource, type) {
  const escaped = type.replace(/\./g, '\\.')
  const block = new RegExp(`extension ${escaped}: Codable \\{[\\s\\S]*?enum CodingKeys[^{]*\\{([\\s\\S]*?)\\n\\s*\\}`).exec(swiftSource)
  if (!block) throw new Error(`${type} CodingKeys not found`)
  const keys = []
  for (const line of block[1].split('\n')) {
    const match = /^\s*case\s+(.+)$/.exec(line)
    if (!match) continue
    for (const item of match[1].split(',')) {
      const [name, raw] = item.split('=').map(s => s.trim())
      keys.push(raw ? raw.replace(/"/g, '') : name)
    }
  }
  return keys
}

/** Every `public let` name of a Swift struct body that starts at `struct <name>`. */
export function storedProperties(swiftSource, name) {
  const start = swiftSource.indexOf(`struct ${name}:`)
  if (start < 0) throw new Error(`struct ${name} not found`)
  let depth = 0
  let body = ''
  for (let i = swiftSource.indexOf('{', start); i < swiftSource.length; i++) {
    const c = swiftSource[i]
    if (c === '{') depth++
    if (c === '}') depth--
    body += c
    if (depth === 0) break
  }
  // Only the struct's own level: drop nested type bodies.
  let flat = ''
  depth = 0
  for (const c of body.slice(1, -1)) {
    if (c === '{') depth++
    else if (c === '}') depth--
    else if (depth === 0) flat += c
  }
  return [...flat.matchAll(/public let (\w+)/g)].map(m => m[1])
}

/** Raw values of the `enum <name>` cases, the `= "…"` raw value when present. */
export function enumRawValues(swiftSource, name) {
  const body = new RegExp(`enum ${name}\\b[^{]*\\{([\\s\\S]*?)\\n\\s*\\}`).exec(swiftSource)
  if (!body) throw new Error(`enum ${name} not found`)
  return [...body[1].matchAll(/^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?/gm)].map(m => m[2] ?? m[1])
}

/** The guarded `swiftgate` verbs `PlanCommandGuard.sessionCommands` lists, as `group verb`. */
export function guardedVerbs(swiftSource) {
  const block = /sessionCommands: Set<\[String\]> = \[([\s\S]*?)\n\s*\]/.exec(swiftSource)
  if (!block) throw new Error('PlanCommandGuard.sessionCommands not found')
  return [...block[1].matchAll(/\["(\w[\w-]*)", "(\w[\w-]*)"\]/g)].map(m => `${m[1]} ${m[2]}`)
}

const taskReturnSource = domainSource('Build/TaskReturn.swift')
const statusSource = domainSource('Plan/TaskStatusReport.swift')
const claimSource = domainSource('Evidence/Claim.swift')

export const RETURN_KEYS = codingKeys(taskReturnSource, 'TaskReturn')
export const GATE_KEYS = codingKeys(taskReturnSource, 'TaskReturn.Gate')
export const REVIEW_KEYS = codingKeys(taskReturnSource, 'TaskReturn.Review')
export const OUTCOMES = enumRawValues(taskReturnSource, 'Outcome')
export const STATUS_KEYS = storedProperties(statusSource, 'TaskStatusReport')
export const REPORT_KEYS = storedProperties(statusSource, 'Report')
export const CITATION_KEYS = storedProperties(claimSource, 'Citation')
export const GUARDED_VERBS = guardedVerbs(domainSource('Hooks/Guards.swift'))

// The command groups neither build agent ever runs. Every verb the guard denies to a subagent
// belongs to one of them; a wildcard form keeps the verbs the guard doesn't deny yet out too.
export const FORBIDDEN_GROUPS = ['ledger set', 'build *', 'worktree *', 'plan *', 'index *']

/** The JSON object in the fence under a prompt's `## Output contract` heading. Throws when absent. */
export function returnExample(body) {
  const section = /^## Output contract\n([\s\S]*?)(?=^## |(?![\s\S]))/m.exec(body)
  if (!section) throw new Error('no `## Output contract` section')
  const fence = /```json\n([\s\S]*?)\n```/.exec(section[1])
  if (!fence) throw new Error('no ```json example in the output contract')
  return JSON.parse(fence[1])
}

const COMMON = {
  tools: ['Read', 'Grep', 'Glob', 'Edit', 'Write', 'Bash'],
  strings: [
    'swiftgate check --tier',
    'GREEN',
    'foreground',
    'never push',
    'Co-Authored-By',
    ...FORBIDDEN_GROUPS.map(g => `\`swiftgate ${g}\``),
  ],
}

// Per agent: its model rule, and the fixed strings its prompt carries.
export const BUILD_CONTRACTS = {
  'build-worker': {
    model: null,
    strings: [
      '.harness/task-status.json',
      '"design-conflict"',
      '"state": "blocked"',
      'test-first',
      'write set',
      'context pack',
      'notes',
      'surface commit',
      '--base main --prove --mutate',
      'no `--prove` or `--mutate`',
    ],
  },
  'build-fixer': {
    model: 'opus',
    strings: [
      'fix worktree',
      'merge gate',
      'both tasks',
      'never commit to `main`',
      'never merge',
      '"gate-red"',
      '"designConflict": null',
    ],
  },
}

/** Every problem with one build agent file, as strings naming the file. Empty means it passes. */
export function checkBuildAgentText(fileName, text) {
  const name = basename(fileName, '.md')
  const problems = []
  const say = message => problems.push(`${fileName}: ${message}`)
  const contract = BUILD_CONTRACTS[name]
  if (!contract) return [`${fileName}: no build agent contract registered`]

  let parsed
  try {
    parsed = parseFrontmatter(text)
  } catch (error) {
    say(error.message)
    return problems
  }
  const { fields, body } = parsed
  if (fields.name !== name) say(`frontmatter name \`${fields.name}\` is not the file name \`${name}\``)
  if (!fields.description) say('frontmatter has no description')
  if (contract.model === null) {
    if ('model' in fields) say(`pins model \`${fields.model}\`; the workflow passes the task's model`)
  } else if (fields.model !== contract.model) {
    say(`model \`${fields.model ?? ''}\` is not \`${contract.model}\``)
  }
  if ('model' in fields && !NATIVE_MODELS.includes(fields.model)) say(`model \`${fields.model}\` is not a native model name`)
  const tools = (fields.tools ?? '').split(',').map(s => s.trim()).filter(Boolean)
  for (const tool of COMMON.tools) if (!tools.includes(tool)) say(`frontmatter tools lack \`${tool}\``)

  for (const { rule, pattern } of AGENT_RULES) {
    if (!pattern.test(body)) say(`prompt is missing the agent rule "${rule}"`)
  }
  for (const fixed of [...COMMON.strings, ...contract.strings]) {
    if (!body.includes(fixed)) say(`prompt is missing \`${fixed}\``)
  }
  const nested = [...RETURN_KEYS, ...GATE_KEYS, ...REVIEW_KEYS]
  for (const key of nested) if (!body.includes(`"${key}"`)) say(`return key "${key}" does not appear`)
  for (const outcome of OUTCOMES) if (!body.includes(`\`${outcome}\``)) say(`outcome \`${outcome}\` is not named`)

  let example
  try {
    example = returnExample(body)
  } catch (error) {
    say(error.message)
    return problems
  }
  const top = Object.keys(example).sort()
  if (top.join(',') !== [...RETURN_KEYS].sort().join(',')) {
    say(`return example keys ${top.join(', ')} are not TaskReturn's ${[...RETURN_KEYS].sort().join(', ')}`)
  }
  if (!OUTCOMES.includes(example.outcome)) say(`return example outcome \`${example.outcome}\` is not a TaskReturn outcome`)
  if (example.gate) {
    const gateKeys = Object.keys(example.gate).sort().join(',')
    if (gateKeys !== [...GATE_KEYS].sort().join(',')) say(`return example gate keys ${gateKeys} are not ${GATE_KEYS.join(', ')}`)
  }

  if (name === 'build-worker') {
    const fences = [...body.matchAll(/```json\n([\s\S]*?)\n```/g)].map(m => JSON.parse(m[1]))
    const status = fences.find(f => f && f.report && f.state)
    if (!status) say('no task-status.json example with `state` and `report`')
    else {
      const want = [...STATUS_KEYS, ...REPORT_KEYS, ...CITATION_KEYS].sort()
      const have = jsonKeys(status)
      const missing = want.filter(k => !have.includes(k))
      const extra = have.filter(k => !want.includes(k))
      if (missing.length) say(`task-status example lacks ${missing.join(', ')}`)
      if (extra.length) say(`task-status example has keys TaskStatusReport doesn't: ${extra.join(', ')}`)
    }
  }
  return problems
}

const failsWith = (fileName, text, fragment) => {
  const problems = checkBuildAgentText(fileName, text)
  assert.ok(
    problems.some(p => p.includes(fragment)),
    `expected a problem containing "${fragment}", got:\n${problems.join('\n')}`,
  )
}

const tests = {
  'the key lists are read from the Swift types — catches this test checking a stale copy of the return shape'() {
    assert.deepEqual(RETURN_KEYS, [
      'task', 'outcome', 'commits', 'gate', 'review', 'testsAdded', 'notes', 'designConflict', 'surfaceCommit',
    ])
    assert.deepEqual(GATE_KEYS, ['tier', 'verdict', 'runId'])
    assert.deepEqual(REVIEW_KEYS, ['mode', 'findings'])
    assert.deepEqual(OUTCOMES, ['ready-to-merge', 'gate-red', 'review-blocked', 'design-conflict'])
    assert.deepEqual(STATUS_KEYS, ['task', 'state', 'report'])
    assert.deepEqual(REPORT_KEYS, ['kind', 'section', 'ids', 'claim', 'evidence'])
    assert.ok(CITATION_KEYS.includes('loc') && CITATION_KEYS.includes('pin'), CITATION_KEYS.join(','))
    assert.ok(GUARDED_VERBS.includes('ledger set') && GUARDED_VERBS.includes('worktree create'), GUARDED_VERBS.join(','))
  },

  'build-worker meets its contract — catches a worker return check-return rejects, or a worker that drops a standing rule'() {
    assert.deepEqual(checkBuildAgentText('build-worker.md', agentText('build-worker')), [])
  },

  'build-fixer meets its contract — catches a fixer that may commit to main, merge, or run off opus'() {
    assert.deepEqual(checkBuildAgentText('build-fixer.md', agentText('build-fixer')), [])
  },

  'the worker leaves its model open and the fixer pins opus — catches a per-task model the agent file overrides'() {
    assert.ok(!('model' in parseFrontmatter(agentText('build-worker')).fields))
    assert.equal(parseFrontmatter(agentText('build-fixer')).fields.model, 'opus')
    const worker = agentText('build-worker')
    failsWith('build-worker.md', worker.replace('\n---\n', '\nmodel: sonnet\n---\n'), 'pins model `sonnet`')
    const fixer = agentText('build-fixer')
    failsWith('build-fixer.md', fixer.replace('model: opus', 'model: sonnet'), 'is not `opus`')
  },

  'a return example with a missing or extra key, or an unknown outcome, fails — catches the example check passing anything'() {
    const worker = agentText('build-worker')
    const example = returnExample(parseFrontmatter(worker).body)
    const swap = replacement => {
      const text = worker.replace(JSON.stringify(example, null, 2), JSON.stringify(replacement, null, 2))
      assert.notEqual(text, worker, 'the output contract example is not pretty-printed JSON with 2-space indent')
      return text
    }
    const { notes, ...noNotes } = example
    failsWith('build-worker.md', swap(noNotes), 'are not TaskReturn')
    failsWith('build-worker.md', swap({ ...example, confidence: 1 }), 'are not TaskReturn')
    failsWith('build-worker.md', swap({ ...example, outcome: 'done' }), 'outcome `done`')
    failsWith('build-worker.md', swap({ ...example, gate: { tier: 'fast', verdict: 'GREEN', run: 'x' } }), 'gate keys')
  },

  'dropping a forbidden command, task-status.json or an agent rule fails — catches the prompt check passing anything'() {
    const worker = agentText('build-worker')
    const drop = (text, fragment) => text.split(fragment).join('')
    failsWith('build-worker.md', drop(worker, '`swiftgate ledger set`'), '`swiftgate ledger set`')
    failsWith('build-worker.md', drop(worker, '`swiftgate worktree *`'), '`swiftgate worktree *`')
    failsWith('build-worker.md', drop(worker, '.harness/task-status.json'), 'task-status.json')
    failsWith('build-worker.md', worker.replace(/diminishing returns/gi, 'the end'), 'diminishing returns')
    failsWith('build-worker.md', worker.replace('tools: ', 'tools: Read, Grep, Glob\nx: '), 'lack `Bash`')
    failsWith('build-fixer.md', drop(agentText('build-fixer'), 'never commit to `main`'), 'never commit to `main`')
  },

  'a task-status example that drifts from TaskStatusReport fails — catches a design-conflict report check-return cannot match'() {
    const worker = agentText('build-worker')
    const fences = [...worker.matchAll(/```json\n([\s\S]*?)\n```/g)].map(m => m[1])
    const statusFence = fences.find(f => f.includes('"report"'))
    assert.ok(statusFence, 'no task-status fence')
    failsWith('build-worker.md', worker.replace(statusFence, statusFence.replace('"claim"', '"summary"')), 'lacks claim')
  },

  'every verb the guard denies to a subagent is in the forbidden list — catches a guard verb added without the prompt learning it'() {
    for (const verb of GUARDED_VERBS) {
      const group = verb.split(' ')[0]
      assert.ok(FORBIDDEN_GROUPS.some(g => g === verb || g === `${group} *`), verb)
    }
  },
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  let failed = 0
  for (const [name, test] of Object.entries(tests)) {
    try {
      await test()
      console.log(`ok   ${name}`)
    } catch (error) {
      failed++
      console.log(`FAIL ${name}\n     ${error.message.split('\n').join('\n     ')}`)
    }
  }
  if (failed) {
    console.log(`${failed} failed`)
    process.exit(1)
  }
}
