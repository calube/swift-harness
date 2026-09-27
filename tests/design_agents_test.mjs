// Checks every agents/design-*.md against the design workflow's agent contract. Run:
// node tests/design_agents_test.mjs
// Regressions caught: a design agent pinned to a relay or proxy agent type or a non-native model
// name; a read-only agent quietly granted a write tool; an agent prompt that drops the read-only
// agent rules or the JSON keys its workflow parses; a research lane citing the web instead of
// pinned checkouts, or relying on an API without a probe; a design reviewer whose promised output
// drifts from the schema workflows/design-review.js validates, or that claims to self-verify.
//
// `checkAgentsDir(dir)` is exported so the checks run against a temp directory as well as the
// repo. A later design agent registers its output contract in CONTRACTS; an agents/design-*.md
// with no registered contract fails.
import assert from 'node:assert/strict'
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// The plugin directory: every path this test reads is relative to it.
const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')

export const NATIVE_MODELS = ['sonnet', 'opus', 'haiku', 'fable']
export const READ_ONLY_TOOLS = ['Read', 'Grep', 'Glob']

// A file may grant itself a tool beyond READ_ONLY_TOOLS only by naming it in this frontmatter
// field, with the reason on the same line: `toolExceptions: Bash — runs swiftgate evidence find`.
export const TOOL_EXCEPTIONS_FIELD = 'toolExceptions'

// Any word containing relay or proxy: the plugin names native models only (spec D2), so a design
// agent file has no reason to spell either.
const RELAY_PATTERN = /[\w-]*(?:relay|proxy)[\w-]*/i

// The read-only agent rules every design agent prompt carries, as phrases the prompt must contain.
export const AGENT_RULES = [
  { rule: 'no subagents of its own', pattern: /subagents?/i },
  { rule: 'stop at diminishing returns', pattern: /diminishing returns/i },
  { rule: 'never contact a human', pattern: /never (?:contact|message|ask) a human/i },
  { rule: 'return once', pattern: /return once/i },
]

// The reviewer schema is read from the workflow itself by running it at deep tier against a stub
// agent that records the options of every call, so a schema change there reaches these checks
// without a copy here to update.
const workflowSource = readFileSync(join(root, 'workflows/design-review.js'), 'utf8').replace(
  /^export const meta/m,
  'const meta',
)
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor

/** `{agentType: schema}` for every reviewer agent design-review.js invokes. */
export async function reviewerSchemas(source = workflowSource) {
  const script = new AsyncFunction('args', 'agent', 'log', 'phase', source)
  const reviewers = ['evidence-auditor', 'standards-reviewer', 'challenger', 'pre-mortem']
  const schemas = {}
  const agent = async (_prompt, opts) => {
    schemas[opts.agentType] = opts.schema
    return { findings: [] }
  }
  await script(
    { tier: 'deep', packs: reviewers.map(reviewer => ({ reviewer, packPath: `${reviewer}.md` })) },
    agent,
    () => {},
    () => {},
  )
  return schemas
}

/** Every property name a JSON schema declares, at any depth. */
export function schemaKeys(schema) {
  const keys = new Set()
  const walk = node => {
    if (!node || typeof node !== 'object') return
    for (const [key, child] of Object.entries(node.properties ?? {})) {
      keys.add(key)
      walk(child)
    }
    walk(node.items)
  }
  walk(schema)
  return [...keys].sort()
}

/** Every object key in a parsed JSON value, at any depth. */
export function jsonKeys(value) {
  const keys = new Set()
  const walk = node => {
    if (Array.isArray(node)) node.forEach(walk)
    else if (node && typeof node === 'object') {
      for (const [key, child] of Object.entries(node)) {
        keys.add(key)
        walk(child)
      }
    }
  }
  walk(value)
  return [...keys].sort()
}

const PLUGIN_AGENT_PREFIX = 'swift-harness:'
const schemasByType = await reviewerSchemas()
export const REVIEWER_AGENTS = Object.keys(schemasByType)
  .map(type => type.slice(PLUGIN_AGENT_PREFIX.length))
  .sort()
const reviewSchema = schemasByType[`${PLUGIN_AGENT_PREFIX}design-challenger`]
export const REVIEWER_KEYS = schemaKeys(reviewSchema)

/** The required-section anchors `DesignDocument.RequiredSection.anchor` returns. */
export function sectionAnchors(swiftSource) {
  const block = /public var anchor: String \{([\s\S]*?)\n    \}/.exec(swiftSource)
  if (!block) throw new Error('RequiredSection.anchor not found')
  return [...block[1].matchAll(/case \.\w+: "([^"]+)"/g)].map(m => m[1])
}

// Output contract per agent-name prefix: the JSON keys (quoted as `"key"`) and the fixed strings
// the prompt must contain. First matching prefix wins.
export const CONTRACTS = [
  {
    prefix: 'design-lane-',
    keys: [
      'lane', 'claims', 'probes', 'needsDecision',
      'id', 'text', 'citation', 'kind', 'loc', 'pin', 'quote', 'status',
      'claimId', 'swift',
      'question', 'options', 'recommendation', 'evidence',
    ],
    strings: [
      '"status": "new"',
      '.build/checkouts/',
      'snapshots/',
      'probes/Probe_',
      '.snippet.swift',
      'sha256:',
      'a probe snippet for every API',
    ],
  },
  { prefix: 'design-evidence-auditor', keys: REVIEWER_KEYS, strings: ['[UNVERIFIED]', 'refuted', 'perf--scale'] },
  {
    prefix: 'design-standards-conformance',
    keys: REVIEWER_KEYS,
    strings: ['"standards-violation"', 'module-kinds', 'test-plan-by-tier'],
  },
  {
    prefix: 'design-challenger',
    keys: REVIEWER_KEYS,
    strings: ['best end-to-end design, not merely a complete one', 'biggest blind spot'],
  },
  { prefix: 'design-pre-mortem', keys: REVIEWER_KEYS, strings: ['shipped and failed', 'perf--scale'] },
]

/** The JSON object under a reviewer prompt's `## Output contract` heading. Throws when absent. */
export function outputExample(body) {
  const section = /^## Output contract\n([\s\S]*?)(?=^## |(?![\s\S]))/m.exec(body)
  if (!section) throw new Error('no `## Output contract` section')
  const fence = /```json\n([\s\S]*?)\n```/.exec(section[1])
  if (!fence) throw new Error('no ```json example in the output contract')
  return JSON.parse(fence[1])
}

/**
 * Problems with one reviewer prompt's output example against the workflow's reviewer schema: its
 * keys must be exactly the schema's, no key may claim verification, and every finding must be
 * located by a design section anchor.
 */
export function checkReviewerExample(fileName, body, { keys, required, anchors }) {
  const problems = []
  const say = message => problems.push(`${fileName}: ${message}`)
  let example
  try {
    example = outputExample(body)
  } catch (error) {
    say(error.message)
    return problems
  }
  const promised = jsonKeys(example)
  const missing = keys.filter(k => !promised.includes(k))
  const extra = promised.filter(k => !keys.includes(k))
  if (missing.length) say(`output example lacks schema keys ${missing.join(', ')}`)
  if (extra.length) say(`output example has keys the reviewer schema does not: ${extra.join(', ')}`)
  const findings = Array.isArray(example.findings) ? example.findings : []
  if (findings.length === 0) say('output example has no findings')
  for (const [index, finding] of findings.entries()) {
    for (const key of required) if (!(key in finding)) say(`example finding ${index + 1} lacks \`${key}\``)
    const anchor = finding.location?.anchor
    if (!anchors.includes(anchor)) say(`example finding ${index + 1} anchor ${JSON.stringify(anchor)} is not a design section anchor`)
  }
  return problems
}

/** The numbered questions under a prompt's `## Questions` heading. */
export function challengerQuestions(body) {
  const section = /^## Questions\n([\s\S]*?)(?=^## |(?![\s\S]))/m.exec(body)
  if (!section) return []
  return [...section[1].matchAll(/^\d+\.\s+(.+)$/gm)].map(m => m[1])
}

/** Parses `---`-fenced frontmatter of `key: value` lines. Throws on a missing or unterminated fence. */
export function parseFrontmatter(text) {
  const lines = text.split(/\r?\n/)
  if (lines[0] !== '---') throw new Error('no frontmatter: the file must start with ---')
  const end = lines.indexOf('---', 1)
  if (end < 0) throw new Error('frontmatter is not closed with ---')
  const fields = {}
  for (const [offset, line] of lines.slice(1, end).entries()) {
    if (line.trim() === '') continue
    const match = /^([A-Za-z][\w-]*):\s*(.*)$/.exec(line)
    if (!match) throw new Error(`frontmatter line ${offset + 2} is not \`key: value\`: ${line}`)
    if (match[1] in fields) throw new Error(`frontmatter repeats \`${match[1]}\``)
    fields[match[1]] = match[2].trim()
  }
  return { fields, body: lines.slice(end + 1).join('\n') }
}

const list = value => (value ?? '').split(',').map(s => s.trim()).filter(Boolean)

/** Every problem with one agent file, as strings naming the file. Empty means it passes. */
export function checkAgentText(fileName, text) {
  const name = basename(fileName, '.md')
  const problems = []
  const say = message => problems.push(`${fileName}: ${message}`)

  const relay = RELAY_PATTERN.exec(text)
  if (relay) say(`names a relay or proxy agent type (\`${relay[0]}\`); use a native model name`)

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
  if (!NATIVE_MODELS.includes(fields.model)) {
    say(`model \`${fields.model ?? ''}\` is not a native model name (${NATIVE_MODELS.join(', ')})`)
  }

  const tools = list(fields.tools)
  if (tools.length === 0) say('frontmatter declares no tools; list them explicitly')
  const exceptions = new Map()
  for (const entry of list(fields[TOOL_EXCEPTIONS_FIELD])) {
    const match = /^(\w+)\s+—\s+\S/.exec(entry)
    if (!match) say(`\`${TOOL_EXCEPTIONS_FIELD}\` entry \`${entry}\` needs \`<Tool> — <reason>\``)
    else exceptions.set(match[1], entry)
  }
  for (const tool of tools) {
    if (!READ_ONLY_TOOLS.includes(tool) && !exceptions.has(tool)) {
      say(`tool \`${tool}\` is not read-only and is not declared in \`${TOOL_EXCEPTIONS_FIELD}\``)
    }
  }

  for (const { rule, pattern } of AGENT_RULES) {
    if (!pattern.test(body)) say(`prompt is missing the read-only agent rule "${rule}"`)
  }

  const contract = CONTRACTS.find(c => name.startsWith(c.prefix))
  if (!contract) {
    say('no output contract registered for this agent in tests/design_agents_test.mjs CONTRACTS')
  } else {
    for (const key of contract.keys) {
      if (!body.includes(`"${key}"`)) say(`output contract key "${key}" does not appear`)
    }
    for (const fixed of contract.strings) {
      if (!body.includes(fixed)) say(`prompt is missing \`${fixed}\``)
    }
  }
  return problems
}

/** Checks every `design-*.md` in `dir`. Returns `{files, problems}`. */
export function checkAgentsDir(dir) {
  const files = readdirSync(dir)
    .filter(f => f.startsWith('design-') && f.endsWith('.md'))
    .sort()
  const problems = files.flatMap(f => checkAgentText(f, readFileSync(join(dir, f), 'utf8')))
  return { files, problems }
}

/** The research lanes the gate's `ResearchLane` enum accepts in a claim's `lane` field. */
export function researchLanes(swiftSource) {
  const body = /enum ResearchLane\b[^{]*\{([^}]*)\}/.exec(swiftSource)
  if (!body) throw new Error('enum ResearchLane not found')
  return [...body[1].matchAll(/case\s+(\w+)(?:\s*=\s*"([^"]+)")?/g)].map(m => m[2] ?? m[1])
}

// The single-step design agents: the claim checker, the drafter and the decomposer. The design
// skill launches each one directly and parses what it returns.
CONTRACTS.push(
  {
    prefix: 'design-claim-checker',
    keys: ['verdicts', 'skipped', 'id', 'status', 'reason'],
    strings: [
      '"status": "supported"',
      '"status": "refuted"',
      '`quote-ok`',
      'overstate',
      'claim-checker',
    ],
  },
  {
    prefix: 'design-drafter',
    keys: [],
    strings: [
      'templates/design-doc.md',
      'skills/prose',
      '`supported`',
      ' — tier T',
      '[UNVERIFIED]',
      'req-',
      'test-',
      'full design doc text',
    ],
  },
  {
    prefix: 'design-decomposer',
    keys: [
      'tasks', 'unresolved',
      'id', 'deps', 'writeSet', 'gate', 'tests', 'covers', 'estLines', 'status', 'worktree',
      'ruleId', 'task', 'reason',
    ],
    strings: [
      '"status": "pending"',
      '[plan]',
      'est_lines_max',
      'est_lines_min',
      'max_modules_per_task',
      'max_tests_per_task',
      'worker_pack_token_budget',
      'actualLines',
      'one fix round',
    ],
  },
)

/** Raw values of a Swift `enum <name>`'s cases, the `= "…"` raw value when present. */
export function swiftEnumRawValues(swiftSource, name) {
  const body = new RegExp(`enum ${name}\\b[^{]*\\{([\\s\\S]*?)\\n\\s*\\}`).exec(swiftSource)
  if (!body) throw new Error(`enum ${name} not found`)
  return [...body[1].matchAll(/^\s*case\s+(\w+)(?:\s*=\s*"([^"]+)")?/gm)].map(m => m[2] ?? m[1])
}

/** `LedgerTask`'s JSON keys, from its `CodingKeys`. */
export function ledgerTaskKeys(swiftSource) {
  const match = /extension LedgerTask: Codable \{[\s\S]*?enum CodingKeys[^{]*\{\s*case ([^\n}]+)/.exec(swiftSource)
  if (!match) throw new Error('LedgerTask CodingKeys not found')
  return match[1].split(',').map(s => s.trim()).filter(Boolean)
}

/** Every `plan-lint.*` rule id in the given sources, with the severity it is reported at. */
export function planLintRules(swiftSources) {
  const ids = new Map()
  const severities = new Map()
  for (const source of swiftSources) {
    for (const m of source.matchAll(/static let (\w+RuleID) = "(plan-lint\.[a-z-]+)"/g)) ids.set(m[1], m[2])
    for (const m of source.matchAll(/ruleID: (\w+RuleID), severity: \.(\w+)/g)) severities.set(m[1], m[2])
  }
  return [...ids].map(([constant, id]) => ({ id, severity: severities.get(constant) }))
}

/** `## ` headings of a markdown text, outside fenced code, in order. */
export function sectionHeadings(markdown) {
  let fenced = false
  const headings = []
  for (const line of markdown.split('\n')) {
    if (line.startsWith('```')) fenced = !fenced
    else if (!fenced && line.startsWith('## ')) headings.push(line.trim())
  }
  return headings
}

const agentText = stem => readFileSync(join(root, 'agents', `${stem}.md`), 'utf8')
const domainSource = relative => readFileSync(join(root, 'gate/Sources/SwiftGateDomain', relative), 'utf8')

// A lane agent that satisfies every check, used as the base for the negative cases so each one
// fails for the single reason it changes.
const validLane = contract => `---
name: design-lane-example
description: Example research lane.
tools: Read, Grep, Glob
model: sonnet
---

Rules: no subagents of your own, stop at diminishing returns, never contact a human, return once.

${contract.keys.map(k => `"${k}"`).join(' ')}
${contract.strings.join(' ')}
`

function withTempAgents(files, body) {
  const dir = mkdtempSync(join(tmpdir(), 'design-agents-'))
  try {
    for (const [name, text] of Object.entries(files)) writeFileSync(join(dir, name), text)
    return body(checkAgentsDir(dir))
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

const laneContract = CONTRACTS.find(c => c.prefix === 'design-lane-')
const base = validLane(laneContract)
const failsWith = (text, fragment) =>
  withTempAgents({ 'design-lane-example.md': text }, ({ problems }) => {
    assert.ok(
      problems.some(p => p.includes(fragment)),
      `expected a problem containing "${fragment}", got:\n${problems.join('\n')}`,
    )
  })

const agentsDir = join(root, 'agents')
const anchors = sectionAnchors(
  readFileSync(join(root, 'gate/Sources/SwiftGateDomain/Design/DesignDocument.swift'), 'utf8'),
)
const reviewContract = () => ({ keys: REVIEWER_KEYS, required: reviewSchema.properties.findings.items.required, anchors })
const reviewerBody = name => parseFrontmatter(readFileSync(join(agentsDir, `${name}.md`), 'utf8')).body

// A reviewer prompt that satisfies every example check, for the negative cases below.
const validReviewerBody = findings => `## Output contract

\`\`\`json
${JSON.stringify({ findings }, null, 2)}
\`\`\`

## Next
`
const exampleFinding = {
  location: { anchor: 'decision' },
  severity: 'major',
  category: 'unsupported-decision',
  title: 't',
  failure_scenario: 's',
  evidence: 'e',
  fix: 'f',
  kind: 'standards-violation',
  rule: 'A1',
}

const tests = {
  'the workflow invokes exactly the four design reviewer agents, each an opus agent file — catches a renamed agent the workflow can no longer launch'() {
    assert.deepEqual(REVIEWER_AGENTS, [
      'design-challenger',
      'design-evidence-auditor',
      'design-pre-mortem',
      'design-standards-conformance',
    ])
    for (const name of REVIEWER_AGENTS) {
      const { fields } = parseFrontmatter(readFileSync(join(agentsDir, `${name}.md`), 'utf8'))
      assert.equal(fields.name, name)
      assert.equal(fields.model, 'opus', name)
    }
  },

  'the reviewer schema is read from the workflow and has no verified key — catches this test checking a stale copy, or a reviewer schema that lets agents self-verify'() {
    const schemas = Object.values(schemasByType)
    assert.equal(schemas.length, 4)
    for (const schema of schemas) assert.deepEqual(schemaKeys(schema), REVIEWER_KEYS)
    assert.ok(REVIEWER_KEYS.includes('anchor') && REVIEWER_KEYS.includes('failure_scenario'), REVIEWER_KEYS.join(','))
    assert.ok(!REVIEWER_KEYS.includes('verified'))
    const edited = workflowSource.replace("title: { type: 'string' },", "title: { type: 'string' },\n  confidence: { type: 'number' },")
    assert.notEqual(edited, workflowSource)
    return reviewerSchemas(edited).then(changed => {
      assert.ok(schemaKeys(Object.values(changed)[0]).includes('confidence'))
    })
  },

  'each reviewer promises exactly the workflow schema keys, located by a section anchor — catches a reviewer output the workflow marks not-reviewed'() {
    const problems = REVIEWER_AGENTS.flatMap(name => checkReviewerExample(`${name}.md`, reviewerBody(name), reviewContract()))
    assert.deepEqual(problems, [])
    for (const name of REVIEWER_AGENTS) {
      assert.ok(!/"verified"/.test(reviewerBody(name)), `${name} quotes a "verified" key`)
    }
  },

  'a reviewer example with an extra, missing or file:line key, or a bad anchor, fails — catches the example check passing anything'() {
    const check = findings => checkReviewerExample('x.md', validReviewerBody(findings), reviewContract()).join('\n')
    assert.equal(check([exampleFinding]), '')
    assert.match(check([{ ...exampleFinding, verified: true }]), /keys the reviewer schema does not: verified/)
    assert.match(check([{ ...exampleFinding, file: 'a.swift', line: 3 }]), /does not: file, line/)
    const { rule, ...noRule } = exampleFinding
    assert.match(check([noRule]), /lacks schema keys rule/)
    const { fix, ...noFix } = exampleFinding
    assert.match(check([noFix, exampleFinding]), /finding 1 lacks `fix`/)
    assert.match(check([{ ...exampleFinding, location: { anchor: '#decision' } }]), /not a design section anchor/)
    assert.match(check([{ ...exampleFinding, location: { anchor: 'Sources/A.swift:12' } }]), /not a design section anchor/)
    assert.match(checkReviewerExample('x.md', '## Other\n', reviewContract()).join('\n'), /no `## Output contract`/)
  },

  'the challenger asks 5 to 7 questions, including the end-to-end and blind-spot questions — catches a question set trimmed or bloated'() {
    const questions = challengerQuestions(reviewerBody('design-challenger'))
    assert.ok(questions.length >= 5 && questions.length <= 7, `${questions.length} questions:\n${questions.join('\n')}`)
    assert.ok(questions.some(q => q.includes('best end-to-end design, not merely a complete one')))
    assert.ok(questions.some(q => q.includes('biggest blind spot')))
    assert.equal(challengerQuestions('## Questions\n\n1. a\n2. b\n\n## Output contract\n3. c\n').length, 2)
  },

  'the verifier has a design findings section that verifies against the anchor and the pack — catches design findings verified by code-only rules'() {
    const text = readFileSync(join(agentsDir, 'verifier.md'), 'utf8')
    const section = /^## Design findings\n([\s\S]*?)(?=^## |(?![\s\S]))/m.exec(text)
    assert.ok(section, 'agents/verifier.md has no `## Design findings` section')
    for (const phrase of ['location.anchor', 'context pack', '`defect`', '`standards-violation`', 'downgrade_reason', 'verification_note']) {
      assert.ok(section[1].includes(phrase), `design findings section lacks ${phrase}`)
    }
  },

  'every agents/design-*.md passes the design agent checks — catches a design agent drifting from D2 or its output contract'() {
    const { files, problems } = checkAgentsDir(join(root, 'agents'))
    assert.ok(files.length > 0, 'no agents/design-*.md found')
    assert.deepEqual(problems, [])
  },

  'every research lane the gate accepts has a lane agent, and each lane agent names an accepted lane — catches a lane the workflow can never run'() {
    const lanes = researchLanes(
      readFileSync(join(root, 'gate/Sources/SwiftGateDomain/Design/DesignMetrics.swift'), 'utf8'),
    )
    assert.ok(lanes.length > 0)
    const agents = readdirSync(join(root, 'agents')).filter(f => /^design-lane-.*\.md$/.test(f))
    const named = agents.map(f => {
      const text = readFileSync(join(root, 'agents', f), 'utf8')
      const match = /"lane":\s*"([^"]+)"/.exec(text)
      assert.ok(match, `${f} never states its "lane" value`)
      return match[1]
    })
    assert.deepEqual([...named].sort(), [...lanes].sort())
  },

  'every lane agent runs on sonnet — catches a lane silently moved to a costlier model'() {
    const agents = readdirSync(join(root, 'agents')).filter(f => /^design-lane-.*\.md$/.test(f))
    for (const f of agents) {
      const { fields } = parseFrontmatter(readFileSync(join(root, 'agents', f), 'utf8'))
      assert.equal(fields.model, 'sonnet', f)
    }
  },

  'a clean temp agent passes — catches the negative cases below failing for an unrelated reason'() {
    withTempAgents({ 'design-lane-example.md': base }, ({ files, problems }) => {
      assert.deepEqual(files, ['design-lane-example.md'])
      assert.deepEqual(problems, [])
    })
  },

  'an agent naming a relay type fails — catches D2 drift'() {
    failsWith(`${base}\nDelegate lookups to the opus-relay agent.\n`, 'relay or proxy')
  },

  'a relay type as the model fails — catches a proxy model slipping past the native-name list'() {
    const text = base.replace('model: sonnet', 'model: sonnet-proxy')
    failsWith(text, 'relay or proxy')
    failsWith(text, 'not a native model name')
  },

  'a non-native model name fails — catches a versioned or aliased model id'() {
    failsWith(base.replace('model: sonnet', 'model: claude-sonnet-4'), 'not a native model name')
  },

  'an undeclared write tool fails, a declared one passes — catches a read-only agent granted Write'() {
    failsWith(base.replace('tools: Read, Grep, Glob', 'tools: Read, Write'), 'tool `Write` is not read-only')
    const declared = base.replace(
      'tools: Read, Grep, Glob',
      'tools: Read, Bash\ntoolExceptions: Bash — runs swiftgate evidence find',
    )
    withTempAgents({ 'design-lane-example.md': declared }, ({ problems }) => assert.deepEqual(problems, []))
    failsWith(
      base.replace('tools: Read, Grep, Glob', 'tools: Read, Bash\ntoolExceptions: Bash'),
      'needs `<Tool> — <reason>`',
    )
  },

  'missing tools fails — catches an agent inheriting every tool by omission'() {
    failsWith(base.replace('tools: Read, Grep, Glob\n', ''), 'declares no tools')
  },

  'a prompt without the read-only agent rules fails — catches a lane that fans out or never returns'() {
    failsWith(base.replace('stop at diminishing returns, ', ''), 'diminishing returns')
    failsWith(base.replace('return once', 'reply when done'), 'return once')
  },

  'a missing output contract key fails — catches a lane returning a shape the workflow cannot parse'() {
    failsWith(base.replace('"needsDecision"', ''), 'key "needsDecision"')
    failsWith(base.replace('"claimId"', ''), 'key "claimId"')
  },

  'a lane prompt without the citation contract fails — catches lanes citing the web or skipping probes'() {
    failsWith(base.replace('.build/checkouts/', ''), '`.build/checkouts/`')
    failsWith(base.replace('a probe snippet for every API', ''), 'a probe snippet for every API')
  },

  'a design agent with no registered contract fails — catches a new agent skipping these checks'() {
    withTempAgents(
      { 'design-mystery.md': base.replace('name: design-lane-example', 'name: design-mystery') },
      ({ problems }) => assert.ok(problems.some(p => p.includes('no output contract registered'))),
    )
  },

  'bad frontmatter and a mismatched name fail — catches an agent Claude Code cannot load'() {
    failsWith(base.replace(/^---\n/, ''), 'no frontmatter')
    failsWith(base.replace('name: design-lane-example', 'name: design-lane-other'), 'is not the file name')
  },

  'non-design agents are not checked — catches the checker claiming files it does not own'() {
    withTempAgents({ 'verifier.md': 'no frontmatter at all' }, ({ files, problems }) => {
      assert.deepEqual(files, [])
      assert.deepEqual(problems, [])
    })
  },
}

Object.assign(tests, {
  'every registered contract has its agent file — catches a design skill launching an agent that does not exist'() {
    const files = readdirSync(join(root, 'agents')).filter(f => f.startsWith('design-') && f.endsWith('.md'))
    const orphans = CONTRACTS.filter(c => !files.some(f => f.startsWith(c.prefix))).map(c => c.prefix)
    assert.deepEqual(orphans, [])
  },

  'the single-step agents run on opus — catches a judgment step moved to a cheaper model'() {
    for (const stem of ['design-claim-checker', 'design-drafter', 'design-decomposer']) {
      assert.equal(parseFrontmatter(agentText(stem)).fields.model, 'opus', stem)
    }
  },

  'every claim status the claim checker writes is a real Claim.Status reachable from quote-ok — catches a verdict the gate cannot decode'() {
    const statuses = swiftEnumRawValues(domainSource('Evidence/Claim.swift'), 'Status')
    assert.ok(statuses.includes('quote-ok'), `Claim.Status parse found ${statuses}`)
    const written = [...agentText('design-claim-checker').matchAll(/"status":\s*"([^"]+)"/g)].map(m => m[1])
    assert.ok(written.length > 0)
    for (const status of written) assert.ok(statuses.includes(status), `"${status}" is not a Claim.Status`)
    assert.deepEqual([...new Set(written)].sort(), ['refuted', 'supported'])
  },

  'the drafter names every template section in the template order — catches a draft whose headings design-lint rejects'() {
    const template = sectionHeadings(readFileSync(join(root, 'templates/design-doc.md'), 'utf8'))
    assert.ok(template.length >= 13, `template headings: ${template}`)
    const drafter = agentText('design-drafter')
    const positions = template.map(h => drafter.indexOf(`\n${h}\n`))
    template.forEach((h, i) => assert.ok(positions[i] >= 0, `drafter never names \`${h}\``))
    assert.deepEqual(positions, [...positions].sort((a, b) => a - b), 'drafter lists the sections out of order')
  },

  'the decomposer emits every LedgerTask key it owns at decomposition time — catches a proposed task the ledger cannot decode or a fabricated line count'() {
    // actualLines and model are written later, by a worker report and the decomposer's own model
    // tag respectively; branch is written by worktree create. None of the three is the
    // decomposer's to emit yet.
    const notYetDecomposerOwned = ['actualLines', 'model', 'branch']
    const keys = ledgerTaskKeys(domainSource('Plan/Ledger.swift'))
    assert.ok(keys.includes('actualLines') && keys.includes('estLines'), `LedgerTask keys: ${keys}`)
    const text = agentText('design-decomposer')
    for (const key of keys.filter(k => !notYetDecomposerOwned.includes(k)))
      assert.ok(text.includes(`"${key}"`), `missing "${key}"`)
    const fences = [...text.matchAll(/```json\n([\s\S]*?)```/g)].map(m => m[1])
    assert.ok(fences.length > 0, 'no json example')
    for (const fence of fences)
      for (const key of notYetDecomposerOwned)
        assert.ok(!fence.includes(`"${key}"`), `a json example sets "${key}"`)
  },

  'the decomposer names every plan-lint rule id — catches a fix round that ignores an error the gate reports'() {
    const rules = planLintRules([domainSource('Plan/PlanLintCoverage.swift'), domainSource('Plan/PlanLintGraph.swift')])
    const gating = rules.filter(r => r.severity === 'major').map(r => r.id)
    assert.ok(gating.length >= 12, `gating plan-lint rules: ${gating}`)
    const text = agentText('design-decomposer')
    const missing = rules.map(r => r.id).filter(id => !text.includes(`\`${id}\``))
    assert.deepEqual(missing, [])
  },
})

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
