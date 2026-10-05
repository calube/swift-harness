// Checks the code-review agents against the review contract. Run: node tests/review_agents_test.mjs
// Regressions caught: a reviewer or verifier citing a `diff.patch` line instead of the line in the
// new file, which lets the workflow mismatch a real finding with its verification; a reviewer that
// never reads the numbered diff that carries the new-file line numbers; the concurrency reviewer
// rating a race users hit below the contract's blocker rule.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..', 'plugin')
// Prose wraps anywhere, so phrases are matched with whitespace collapsed.
const read = path => readFileSync(join(root, path), 'utf8').replace(/\s+/g, ' ')

const REVIEWERS = ['concurrency', 'architecture', 'test-quality', 'api-errors', 'swiftui']
const CODE_AGENTS = [...REVIEWERS, 'verifier']

// The contract's defect-severity sentence, read from the contract so the two can't drift.
const contract = read('docs/review-contract.md')
const SEVERITY_RULES = ['defect-users-hit', 'defect-narrow-trigger', 'structural-fix', 'do-violation', 'no-harm-yet', 'taste']
const DEFECT_BLOCKER_RULE = /A defect is a `blocker` when users or callers hit it/.exec(contract)?.[0]

const frontmatter = name => {
  const text = readFileSync(join(root, `agents/${name}.md`), 'utf8')
  const block = /^---\n([\s\S]*?)\n---\n/.exec(text)?.[1] ?? ''
  return Object.fromEntries(block.split('\n').map(line => /^(\w+):\s*(.*)$/.exec(line)).filter(Boolean).map(m => [m[1], m[2]]))
}
const toolList = value => (value ?? '').split(',').map(s => s.trim()).filter(Boolean)

const tests = {
  'every code reviewer and the verifier holds only Read, Grep and Glob, and none is told to run a span line — catches the 14 guard.reviewer-bash refusals 1 run\'s reviewers and verifiers spent chaining span lines and reading files through Bash'() {
    for (const name of CODE_AGENTS) {
      const fields = frontmatter(name)
      assert.deepEqual(toolList(fields.tools), ['Read', 'Grep', 'Glob'], `${name}: tools`)
      assert.equal(fields.toolExceptions, undefined, `${name}: declares a tool exception`)
      const body = read(`agents/${name}.md`)
      assert.ok(!/events span|span line/.test(body), `${name}: still told to run a span line`)
    }
  },

  'every code-review agent says line is the new-file line, never a patch line — catches findings citing diff.patch lines that reconcile cannot line up'() {
    for (const name of CODE_AGENTS) {
      const body = read(`agents/${name}.md`)
      assert.match(body, /`line` is the 1-based line in the new file/, `${name}: no new-file line rule`)
      assert.match(body, /never a line number in `diff\.patch`/, `${name}: does not forbid patch lines`)
    }
  },

  'every code-review agent reads the numbered diff — catches reviewers left to count patch lines by hand'() {
    for (const name of CODE_AGENTS) {
      assert.match(read(`agents/${name}.md`), /`diff-numbered\.txt`/, `${name}: never names diff-numbered.txt`)
    }
  },

  'the concurrency reviewer quotes the contract blocker rule with a race users hit — catches a user-visible race rated minor'() {
    assert.ok(DEFECT_BLOCKER_RULE, 'review-contract.md lost its defect blocker rule')
    const body = read('agents/concurrency.md')
    assert.ok(body.includes(DEFECT_BLOCKER_RULE), 'concurrency.md does not quote the contract rule')
    assert.match(body, /race a user can trigger[^.]*is a `blocker`/i, 'no race example rated blocker')
  },

  'the verifier names every contract severity rule, records the one it applied, and files the tap-then-Dismiss race under defect-users-hit — catches a user-visible race left at the reviewer rating'() {
    const body = read('agents/verifier.md')
    for (const rule of SEVERITY_RULES) {
      assert.ok(contract.includes(`\`${rule}\``), `review-contract.md never defines ${rule}`)
      assert.ok(body.includes(`\`${rule}\``), `verifier.md never names ${rule}`)
    }
    assert.match(body, /`severity_rule`/, 'verifier.md never asks for severity_rule')
    assert.match(body, /taps Fact, then Dismiss[^.]*\. [^.]*`defect-users-hit`/, 'no tap-then-Dismiss example under defect-users-hit')
  },

  'the contract states the dedupe window and the pre-existing rule synthesis applies — catches synthesis behaviour the agents and the user cannot read'() {
    assert.match(contract, /within 3 lines/, 'no dedupe window in the contract')
    assert.match(contract, /## Pre-existing defects/, 'no pre-existing section')
    assert.match(contract, /`diff-numbered\.txt`/, 'pre-existing rule does not name the numbered diff')
    assert.match(contract, /never counts? toward the verdict/, 'pre-existing findings may still count')
  },

  'reviewers and the verifier cite the line of the wrong code, so baseline code keeps its own line — catches a baseline defect cited at the new call site and blocking a clean change'() {
    for (const name of CODE_AGENTS) {
      assert.match(read(`agents/${name}.md`), /cite the line of the code that is wrong/i, `${name}: no wrong-code line rule`)
    }
  },

  'the verifier and the build reviewers state when a finding defers to a sibling task, and that a standards violation or the task\'s own behaviour never does — catches a build task review-blocked for a test only a parallel task\'s code could make pass'() {
    const verifier = read('agents/verifier.md')
    assert.match(verifier, /`deferred_to`/, 'verifier.md never names deferred_to')
    assert.match(verifier, /could pass only once that sibling merges/, 'verifier.md lacks the deferral test')
    assert.match(verifier, /[Nn]ever defer a standards violation/, 'verifier.md lets a standards violation defer')
    assert.match(verifier, /this task's own (write set|code)/, 'verifier.md lets the task\'s own behaviour defer')
    for (const name of ['test-quality', 'architecture']) {
      const body = read(`agents/${name}.md`)
      assert.match(body, /sibling tasks/i, `${name}: never mentions sibling tasks`)
      assert.match(body, /name that sibling in its `evidence`/, `${name}: not told to name the sibling`)
    }
  },

  'the review skill saves the workflow result and hands it to review-synth — catches the telemetry file never getting the token counts'() {
    const skill = read('skills/review/SKILL.md')
    assert.match(skill, /review-workflow\.json/)
    assert.match(skill, /review-synth --run-directory \S+ --workflow-result \S+review-workflow\.json/)
    assert.match(skill, /review-telemetry\.json/)
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
