// Checks that nothing under plugin/ reaches outside plugin/. Install copies only the plugin
// directory, so a path that leaves it resolves to nothing on a consumer's machine, and a contract
// read from a contributor doc (docs/adrs, docs/designs, docs/plans, docs/handoffs) silently
// vanishes. Run: node tests/plugin_boundary_test.mjs
// Regressions caught: a `../` reference or a markdown link that climbs above plugin/, a relative
// link that no longer resolves after a move, and a `${CLAUDE_PLUGIN_ROOT}/…` path the plugin
// doesn't ship.
import assert from 'node:assert/strict'
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const checkout = join(dirname(fileURLToPath(import.meta.url)), '..')
const plugin = join(checkout, 'plugin')

// Build output never ships from git, and gate/Tests is the one contributor-only part of the
// plugin (ADR 0002): its fixtures model hostile paths on purpose.
const SKIPPED = new Set(['.build', '.swiftpm', 'node_modules', '.harness'])
const CONTRIBUTOR_ONLY = ['gate/Tests']
// Templates are stamped into an app repository and gate fixtures are docs of the throwaway repos a
// test builds, so their relative links resolve there, not in plugin/. They still can't climb out.
const FOREIGN_LINKS = ['templates/', 'gate/Fixtures/']

function files(root, dir = root) {
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    const rel = relative(root, path)
    if (SKIPPED.has(entry.name) || CONTRIBUTOR_ONLY.includes(rel)) continue
    if (entry.isDirectory()) out.push(...files(root, path))
    else if (entry.isFile()) out.push(path)
  }
  return out.sort()
}

function isText(buffer) {
  return !buffer.subarray(0, 8000).includes(0)
}

const PARENT_TOKEN = /(?<![\w./-])((?:\.\.\/)+[\w@.+\-/]*)/g
const MARKDOWN_LINK = /\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g
const PLUGIN_ROOT_PATH = /\$\{?CLAUDE_PLUGIN_ROOT\}?\/([\w@.+\-/<>*]+)/g
const FENCE = /^([ \t]*)(```|~~~)[^\n]*\n[\s\S]*?^\1\2[^\n]*$/gm
const CODE_SPAN = /(`+)[^`\n]*?\1/g

// Code is quoted, not linked: blank it out, keeping offsets so line numbers stay true.
const withoutCode = text =>
  text.replace(FENCE, m => m.replace(/[^\n]/g, ' ')).replace(CODE_SPAN, m => ' '.repeat(m.length))

// Every way `file`'s text reaches a path, and why that path is wrong. Returns [] for a clean file.
export function violations(root, file, text) {
  const out = []
  const rel = relative(root, file)
  const inside = target => target === root || target.startsWith(root + sep)
  const where = index => `${rel}:${text.slice(0, index).split('\n').length}`

  for (const match of text.matchAll(PARENT_TOKEN)) {
    const target = resolve(dirname(file), match[1])
    if (!inside(target)) {
      out.push(`${where(match.index)}: \`${match[1]}\` climbs above plugin/ to ${relative(root, target)}`)
    }
  }
  if (file.endsWith('.md')) {
    for (const match of withoutCode(text).matchAll(MARKDOWN_LINK)) {
      const link = match[1].split('#')[0]
      if (!link || /^[a-z][a-z0-9+.-]*:/i.test(link) || link.startsWith('/') || link.startsWith('$')) continue
      const target = resolve(dirname(file), decodeURIComponent(link))
      if (!inside(target)) {
        out.push(`${where(match.index)}: link ${match[1]} leaves plugin/`)
      } else if (!FOREIGN_LINKS.some(prefix => rel.startsWith(prefix)) && !existsSync(target)) {
        out.push(`${where(match.index)}: link ${match[1]} resolves to nothing in plugin/`)
      }
    }
  }
  for (const match of text.matchAll(PLUGIN_ROOT_PATH)) {
    const path = match[1].replace(/[.,:;]+$/, '')
    if (!inside(resolve(root, path))) {
      out.push(`${where(match.index)}: \${CLAUDE_PLUGIN_ROOT}/${path} climbs above plugin/`)
    } else if (!/[<>*]/.test(path) && !existsSync(join(root, path))) {
      out.push(`${where(match.index)}: \${CLAUDE_PLUGIN_ROOT}/${path} is not in plugin/`)
    }
  }
  return out
}

export function scan(root) {
  const out = []
  for (const file of files(root)) {
    const buffer = readFileSync(file)
    if (isText(buffer)) out.push(...violations(root, file, buffer.toString('utf8')))
  }
  return { count: files(root).length, problems: out }
}

function fakePlugin(entries) {
  const base = mkdtempSync(join(tmpdir(), 'plugin-boundary-'))
  const root = join(base, 'plugin')
  mkdirSync(join(base, 'docs/designs'), { recursive: true })
  writeFileSync(join(base, 'docs/designs/spec.md'), '# spec\n')
  for (const [path, text] of Object.entries(entries)) {
    mkdirSync(dirname(join(root, path)), { recursive: true })
    writeFileSync(join(root, path), text)
  }
  return { base, root }
}

const tests = {
  'a planted ../docs/… reference, an escaping link and a missing plugin-root path are each found — catches a check that reports nothing'() {
    const { base, root } = fakePlugin({
      'docs/standards.md': 'See [the spec](../../docs/designs/spec.md) for why.\n',
      'skills/review/SKILL.md': 'Read `../../../docs/designs/spec.md` first.\n[gone](../../docs/removed.md)\n',
      'workflows/review.js': 'const C = `${CLAUDE_PLUGIN_ROOT}/docs/adrs/0001.md`\n',
      'bin/swiftgate': 'cat "${CLAUDE_PLUGIN_ROOT}/../docs/designs/spec.md"\n',
    })
    try {
      const { problems } = scan(root)
      const text = problems.join('\n')
      assert.match(text, /docs\/standards\.md:1: .*climbs above plugin\/ to \.\.\/docs\/designs\/spec\.md/)
      assert.match(text, /docs\/standards\.md:1: link \.\.\/\.\.\/docs\/designs\/spec\.md leaves plugin\//)
      assert.match(text, /skills\/review\/SKILL\.md:1: `\.\.\/\.\.\/\.\.\/docs\/designs\/spec\.md` climbs/)
      assert.match(text, /skills\/review\/SKILL\.md:2: link \.\.\/\.\.\/docs\/removed\.md resolves to nothing/)
      assert.match(text, /workflows\/review\.js:1: \$\{CLAUDE_PLUGIN_ROOT\}\/docs\/adrs\/0001\.md is not in plugin\//)
      assert.match(text, /bin\/swiftgate:1: .*climbs above plugin\//)
    } finally {
      rmSync(base, { recursive: true, force: true })
    }
  },

  'references that stay inside plugin/ pass, and stamped templates may link into the app repo — catches the check flagging legitimate paths'() {
    const { base, root } = fakePlugin({
      'docs/standards.md': '# Standards\n\nSee [the playbook](testing-playbook.md#tiers) and [hooks](hooks.md).\n',
      'docs/testing-playbook.md': '# Playbook\n',
      'docs/hooks.md': 'A write through `../` or a sibling worktree `../app-task` is judged by its real path.\n',
      'templates/docs-index.md': '[`../AGENTS.md`](../AGENTS.md)\n',
      'skills/review/SKILL.md':
        'Read `${CLAUDE_PLUGIN_ROOT}/docs/standards.md` and `${CLAUDE_PLUGIN_ROOT}/agents/<focus>.md`.\n' +
        'Cite a design as `[title](designs/<slug>.md)`.\n\n```md\n[x](designs/<slug>.md)\n```\n',
      'gate/Fixtures/docs-lint/broken/docs/index.md': '[missing](designs/does-not-exist.md)\n',
    })
    try {
      assert.deepEqual(scan(root).problems, [])
    } finally {
      rmSync(base, { recursive: true, force: true })
    }
  },

  'nothing under plugin/ references a path above plugin/ — catches a consumer runtime read of a contributor doc'() {
    const { count, problems } = scan(plugin)
    assert.ok(count > 100, `only ${count} files scanned under plugin/`)
    assert.deepEqual(problems, [])
  },
}

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
