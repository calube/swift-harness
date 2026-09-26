// Checks every `swiftgate` / `"$SG"` invocation written in any skills/**/*.md against the real
// binary's `--help` for that subcommand path.
// Run: node tests/skill_commands_test.mjs
// Regressions caught: a skill naming a subcommand or flag the CLI doesn't have (instructions
// drifting from the CLI), and an extractor that silently stops finding invocations.
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
        if (words.length) found.push({ line: startLine, words, isCode: segment.isCode })
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

const tests = {
  'every swiftgate subcommand and flag any skill names exists in the real CLI — catches skill instructions drifting from the CLI'() {
    const { problems, resolved } = scanSkills(join(root, 'skills'), help, root)
    assert.deepEqual(problems, [])
    // The extractor must keep finding what's there: a regex that stops matching would pass above.
    assert.ok(resolved.length >= 40, `only ${resolved.length} invocations found`)
    const has = (file, path, flag) => resolved.some(r => r.file === file && r.path === path && (!flag || r.flags.includes(flag)))
    assert.ok(has('skills/review/SKILL.md', 'review-synth', '--run-directory'))
    assert.ok(has('skills/design/SKILL.md', 'plan claim', '--session'), 'design skill claims the plan with --session')
    assert.ok(has('skills/design/references/frame-research-verify.md', 'evidence check', '--json'), 'reference files are scanned')
    assert.ok(has('skills/design/references/frame-research-verify.md', 'context-pack', '--role'))
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
