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
const REQUIRED_BUILD_TASK_ARGS = ['task:', 'plan:', 'worktree:', 'branch:', 'writeSet:', 'taskGate:', 'tests:', 'contextPack:', 'model:', 'review:']
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

const tests = {
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
        'demo/references/deep.md:1: `swiftgate evidence` has no subcommand `verify` (has: check, capture, find)',
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
