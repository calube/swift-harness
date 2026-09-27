// Runs the plan-state commands the design and plan skills write, in the order they write them, as
// two sessions against a scratch git repository and the real swiftgate binary.
// Run: node tests/design_session_handoff_test.mjs   (SWIFTGATE_BIN=plugin/bin/swiftgate to use the shim)
// Regressions caught: a design session that keeps its plan claim after approval, so /plan in a new
// session is refused; an approval wait that a later session can't resume; a re-scope that leaves
// plan.json at the frame's tier; and a skill step whose command no longer parses or runs.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
const designSkill = join(root, 'skills/design')
const planSkill = join(root, 'skills/plan/SKILL.md')

// An explicit binary first, then the debug build `swift test` keeps fresh, then the shim. The
// shim's cold release build outlasts the repository-script timeout, so it comes last.
function swiftgateBinary() {
  if (process.env.SWIFTGATE_BIN) return process.env.SWIFTGATE_BIN
  const debug = join(root, 'gate/.build/debug/swiftgate')
  return existsSync(debug) ? debug : join(root, 'bin/swiftgate')
}

// The text under `heading` (an exact heading line), up to the next heading of the same or a
// higher level.
export function section(markdown, heading) {
  const lines = markdown.split('\n')
  const start = lines.indexOf(heading)
  assert.ok(start >= 0, `no heading ${JSON.stringify(heading)}`)
  const level = heading.match(/^#+/)[0].length
  const end = lines.findIndex((line, i) => i > start && /^#+ /.test(line) && line.match(/^#+/)[0].length <= level)
  return lines.slice(start, end < 0 ? lines.length : end).join('\n')
}

const STATE_VERB = /^(plan (claim|release|set)|index set)\b/

// Every `"$SG" plan claim|release|set` and `"$SG" index set` command in `text`, in order: fenced
// lines (joining `\` continuations) and inline code spans. A `--force` command is the user's, never
// the skill's, so it's left out.
export function stateCommands(text) {
  const found = []
  let fenced = false
  const lines = text.split('\n')
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i]
    if (/^\s*```/.test(line)) {
      fenced = !fenced
      continue
    }
    const candidates = []
    if (fenced) {
      while (/\\\s*$/.test(line) && i + 1 < lines.length) line = line.replace(/\\\s*$/, ' ') + lines[++i].trim()
      const at = line.indexOf('"$SG" ')
      if (at >= 0) candidates.push(line.slice(at + 6).trim())
    } else {
      for (const m of line.matchAll(/`"\$SG" ([^`]+)`/g)) candidates.push(m[1].trim())
    }
    for (const command of candidates) {
      const normal = command.replace(/\s+/g, ' ')
      if (STATE_VERB.test(normal) && !/--force\b/.test(normal)) found.push(normal)
    }
  }
  return found
}

// Shell words of one command line: double-quoted strings stay whole, without their quotes.
function words(command) {
  return [...command.matchAll(/"([^"]*)"|(\S+)/g)].map(m => m[1] ?? m[2])
}

// Fills the skills' placeholders. An unquoted placeholder the scenario doesn't know fails, so a
// new required argument can't slip through as literal text.
function fill(command, values) {
  return words(command).map((word, index) => {
    const bare = /^<([^>]+)>$/.exec(word)
    if (!bare) return word.replace(/<([^>]+)>/g, (all, name) => values[name] ?? all)
    assert.ok(bare[1] in values, `\`${command}\`: no value for word ${index + 1}, ${word}`)
    return values[bare[1]]
  })
}

function scratchRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'design-session-handoff-'))
  const git = (...args) => execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.com', ...args], { cwd: dir, stdio: 'pipe' })
  git('init', '-q', '-b', 'main')
  git('commit', '-q', '--allow-empty', '-m', 'init')
  return dir
}

function withRepo(body) {
  const dir = scratchRepo()
  const binary = swiftgateBinary()
  const plans = join(dir, '.git', 'swift-harness', 'plans')
  // Runs 1 skill command as `session`; returns {status, json}.
  const run = (command, values) => {
    const argv = fill(command, values)
    const result = spawnSync(binary, argv, {
      cwd: dir,
      encoding: 'utf8',
      env: { ...process.env, LLVM_PROFILE_FILE: join(dir, '.git', 'profile-%p.profraw') },
      timeout: 55_000,
    })
    assert.equal(result.error, undefined, `${argv.join(' ')}: ${result.error}`)
    let json = null
    try {
      json = JSON.parse(result.stdout)
    } catch {}
    return { status: result.status, json, text: `${argv.join(' ')}\n${result.stdout}${result.stderr}` }
  }
  const planFile = slug => JSON.parse(readFileSync(join(plans, slug, 'plan.json'), 'utf8'))
  try {
    return body({ run, planFile, plans })
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

function markdownFilesUnder(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap(entry =>
    entry.isDirectory() ? markdownFilesUnder(join(dir, entry.name)) : entry.name.endsWith('.md') ? [join(dir, entry.name)] : [])
}

const frameRef = () => readFileSync(join(designSkill, 'references/frame-research-verify.md'), 'utf8')
const reviewRef = () => readFileSync(join(designSkill, 'references/review-publish-amend.md'), 'utf8')

const SLUG = '2026-09-27-offline-order-queue'
const DOC = 'docs/ordering/designs/offline-order-queue.md'
const base = session => ({ plan: SLUG, slug: SLUG, id: session, session, doc: DOC, sha: 'f'.repeat(40), page: 'https://claude.ai/code/artifact/x', note: 'n' })

function only(commands, verb, where) {
  const matching = commands.filter(c => c.startsWith(verb))
  assert.ok(matching.length >= 1, `${where} runs no \`${verb}\``)
  return matching
}

// The frame's claim of a new plan: its first `plan claim` names the design doc.
function frameClaim(run, session, tier) {
  const claim = only(stateCommands(section(frameRef(), '### Claim')), 'plan claim', 'the frame\'s Claim step').find(c => c.includes('--design'))
  assert.ok(claim, 'the frame claims no plan with --design')
  const result = run(claim, { ...base(session), tier })
  assert.equal(result.status, 0, result.text)
}

const tests = {
  'a design approved in one session can be claimed by /plan in a new session — catches the design session keeping its claim after approval'() {
    withRepo(({ run, planFile }) => {
      frameClaim(run, 'session-design', 'standard')
      const approved = stateCommands(section(reviewRef(), '### Approved'))
      for (const command of approved) {
        const result = run(command, base('session-design'))
        assert.equal(result.status, 0, result.text)
      }
      const planClaim = only(stateCommands(section(readFileSync(planSkill, 'utf8'), '## 1. Hold the claim')), 'plan claim', 'the plan skill')[0]
      const claimed = run(planClaim, base('session-plan'))
      assert.equal(claimed.status, 0, claimed.text)
      assert.equal(claimed.json?.status, 'claimed', claimed.text)
      assert.equal(planFile(SLUG).design, DOC)
    })
  },

  'an approval wait stopped in one session resumes in another — catches in-review resume refused by the earlier session\'s claim'() {
    withRepo(({ run }) => {
      frameClaim(run, 'session-design', 'standard')
      const read = stateCommands(section(reviewRef(), '### Read the approval'))
      const claims = only(read, 'plan claim', 'Read the approval')
      const releases = only(read, 'plan release', 'Read the approval (the stop route)')
      for (const command of releases) {
        const result = run(command, base('session-design'))
        assert.equal(result.status, 0, result.text)
      }
      const resumed = run(claims[0], base('session-resume'))
      assert.equal(resumed.status, 0, resumed.text)
      assert.equal(resumed.json?.status, 'claimed', resumed.text)
      // The holder is the resuming session now: the earlier one can't take it back silently.
      const earlier = run(claims[0], base('session-design'))
      assert.equal(earlier.status, 1, earlier.text)
      assert.equal(earlier.json?.holder, 'session-resume', earlier.text)
    })
  },

  'revise from comments claims the plan before it touches it — catches --revise in a new session hitting the edit guard'() {
    withRepo(({ run }) => {
      frameClaim(run, 'session-design', 'standard')
      const release = only(stateCommands(section(reviewRef(), '### Read the approval')), 'plan release', 'Read the approval')[0]
      assert.equal(run(release, base('session-design')).status, 0)
      const revise = stateCommands(section(reviewRef(), '## Revise from comments'))
      assert.ok(revise[0]?.startsWith('plan claim'), `Revise from comments starts with ${JSON.stringify(revise[0])}, not a claim`)
      const claimed = run(revise[0], base('session-revise'))
      assert.equal(claimed.status, 0, claimed.text)
    })
  },

  're-scoping a claimed plan updates plan.json\'s tier, sketch included — catches plan.json keeping the frame\'s first tier'() {
    withRepo(({ run, planFile }) => {
      frameClaim(run, 'session-design', 'quick')
      assert.equal(planFile(SLUG).tier, 'quick')
      const set = only(stateCommands(section(frameRef(), '### Claim')), 'plan set', 'the frame\'s Claim step')[0]
      assert.match(set, /--tier <tier>/)
      for (const tier of ['deep', 'sketch', 'standard']) {
        const result = run(set, { ...base('session-design'), tier })
        assert.equal(result.status, 0, result.text)
        assert.equal(planFile(SLUG).tier, tier)
      }
      assert.notEqual(planFile(SLUG).resume, 'framing')
      // Only the holder re-scopes.
      const other = run(set, { ...base('session-other'), tier: 'quick' })
      assert.equal(other.status, 1, other.text)
      assert.equal(planFile(SLUG).tier, 'standard')
    })
  },

  'the design skill never runs plan release --force itself — catches the skill taking over another session\'s lock'() {
    const own = markdownFilesUnder(designSkill).flatMap(path =>
      readFileSync(path, 'utf8').split('\n').map((line, i) => [`${path.slice(root.length + 1)}:${i + 1}`, line]))
      .filter(([, line]) => /"\$SG" plan release[^`\n]*--force/.test(line))
    assert.deepEqual(own.map(([where]) => where), [])
  },

  'the command extractor finds fenced, continued and inline commands and skips --force — catches a scenario that runs nothing'() {
    const text = [
      'Run `"$SG" plan claim <plan> --session <id> --json` first.',
      'Only the user runs `"$SG" plan release <plan> --force`.',
      '```bash',
      '"$SG" index set <plan> approved "a <sha>" \\',
      '  --session <id>',
      '"$SG" docs-lint --json',
      '```',
    ].join('\n')
    assert.deepEqual(stateCommands(text), [
      'plan claim <plan> --session <id> --json',
      'index set <plan> approved "a <sha>" --session <id>',
    ])
    assert.deepEqual(fill('index set <plan> approved "a <sha>" --session <id>', { plan: 'p', sha: 's', id: 'i' }),
      ['index', 'set', 'p', 'approved', 'a s', '--session', 'i'])
    assert.throws(() => fill('plan claim <plan> --tier <tier>', { plan: 'p' }), /no value for word 5/)
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
