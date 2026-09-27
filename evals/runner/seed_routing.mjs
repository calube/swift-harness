// Writes the skill-routing cases for the foundation skills under evals/cases/routing/<skill>/ from
// the requests below. Run: node evals/runner/seed_routing.mjs
//
// Each request names the skill it is written against, whether that skill should load, the skill
// that should load instead (`none` when no harness skill fits), its split and 2 paraphrases. A
// paraphrase becomes 1 case. Both paraphrases of a request share a split, so wording never leaks
// from the tuning set into the held-out set. Source: suites.md, skill-routing.
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const cases = join(root, 'evals/cases/routing')

export const SUITE_TAG = 'routing-foundation'

// [slug, expected skill or 'none', split, why, [paraphrase a, paraphrase b]]
// A should-trigger request expects the skill it is filed under.
const requests = {
  tdd: {
    should: [
      ['counter-below-zero', 60, 'a bug report in plain words, with no mention of tests', [
        'Tapping minus when the count is 0 takes it to -1. It should stop at 0. Can you fix that?',
        'Bug: the counter goes below zero if you keep hitting decrement. Make it stay at zero.',
      ]],
      ['counter-reset-action', 60, 'a small new behaviour on an existing reducer', [
        'Add a reset action to the counter that puts the count back to 0.',
        'I want the counter feature to support resetting to zero. Can you add that?',
      ]],
      ['engine-score-carries-over', 60, 'a bug in a non-TCA engine module', [
        'When a new game starts in GameEngine, the old score carries over. It should start from zero.',
        'New games in the game engine keep the previous game\'s score. Please fix that.',
      ]],
      ['counter-step-size', 40, 'a feature request phrased as a product change', [
        'Make the counter step configurable, so increment adds the step instead of always 1.',
        'Let the counter go up by a custom amount instead of just 1 each tap.',
      ]],
      ['failing-client-test', 40, 'fixing a test that has gone red', [
        'One of the APIClient tests started failing after my last change. Get it passing again.',
        'There\'s a failing test in the HTTPClient package. Can you sort it out?',
      ]],
    ],
    near: [
      ['judge-new-tests-before-pr', 'test-gate', 60, 'shares "tests"; asks for the pre-PR gate', [
        'Before I open the PR, check that the tests I added are real tests and not filler.',
        'Are my new tests actually testing anything? Gate the branch before I mark it ready.',
      ]],
      ['explain-test-first', 'none', 60, 'shares "TDD"; asks for an explanation only', [
        'Explain the difference between TDD and writing tests after the code. A couple of paragraphs, no code.',
        'What\'s the point of watching a test fail before you make it pass? Just explain it.',
      ]],
      ['comments-after-bug-fix', 'comment-audit', 60, 'shares "bug fix"; asks about the comments', [
        'I fixed the counter bug. Now look over the comments I added and tell me which ones to cut.',
        'The bug fix is done. Are the comments in my change worth keeping?',
      ]],
      ['testing-section-after-fix', 'validate', 40, 'shares "fix" and "tests"; asks for PR evidence', [
        'The fix is done and the tests pass. Write the "How this was tested" section for my PR.',
        'I\'ve finished the bug fix. Give me the testing evidence block for the pull request description.',
      ]],
      ['list-counter-tests', 'none', 40, 'shares "tests"; a read-only question', [
        'How many tests are in CounterFeatureTests? Just list their names.',
        'List the test functions in the counter\'s test file.',
      ]],
    ],
  },
  architecture: {
    should: [
      ['settings-screen', 60, 'a new screen with no word about modules', [
        'I want to add a settings screen where people pick a theme. Where should that code go?',
        'Add a new Settings feature to the app. Set up whatever module it needs.',
      ]],
      ['subscriptions-sdk-client', 60, 'wrapping a vendor SDK', [
        'We need to wrap the RevenueCat SDK so the app can check subscriptions. Set up the client for it.',
        'How should I structure a subscriptions service that talks to StoreKit? Set it up.',
      ]],
      ['timer-module-kind', 60, 'asks which kind a module should be', [
        'Should the countdown timer logic be a TCA feature or a plain engine?',
        'I\'m adding a countdown timer. Is that a reducer, an engine or a library?',
      ]],
      ['ui-framework-in-core', 40, 'an arch finding named in the prompt', [
        'swiftgate arch says arch.ui-framework-in-core for CounterCore. Fix the layout.',
        'The arch check flags SwiftUI imported in a Core module. Sort out the module structure.',
      ]],
      ['persistence-package', 40, 'a new IO package', [
        'Add a persistence layer so the counter survives an app restart. It should be its own package.',
        'I need a new module that saves app data to disk. Scaffold it.',
      ]],
    ],
    near: [
      ['offline-sync-design-doc', 'design', 60, 'shares "how should we build"; asks for a design doc', [
        'Write a design doc for how we should build offline sync.',
        'Before we build anything, I want a proper design for offline sync, reviewed and approved.',
      ]],
      ['review-module-boundaries', 'review', 60, 'shares "architecture"; asks for a code review', [
        'Review my branch, and look closely at whether the module boundaries are right.',
        'Is this branch mergeable? Check the architecture and the TCA fit as part of the review.',
      ]],
      ['describe-package-graph', 'none', 60, 'shares "modules"; a read-only question', [
        'Which packages does this app have, and which depends on which? Just describe them.',
        'Give me a quick overview of the modules in this app and how they depend on each other.',
      ]],
      ['double-action-existing-feature', 'tdd', 40, 'shares "feature"; changes an existing reducer', [
        'Add a "double" action to the existing counter feature that doubles the count.',
        'The counter needs a button that doubles the current value. Add it to the existing reducer.',
      ]],
      ['explain-core-ui-split', 'none', 40, 'shares "Core" and "UI"; asks for general knowledge', [
        'In general, why do people split SwiftUI apps into separate Core and UI packages?',
        'Explain the idea behind keeping a Core module free of SwiftUI. General answer, not about this repo.',
      ]],
    ],
  },
  review: {
    should: [
      ['merge-ready-before-teammate', 60, 'asks for a merge verdict before a human reviews', [
        'Can you look over my branch before I ask a teammate? Tell me if it\'s good to merge.',
        'Give my changes a proper code review and tell me whether to merge.',
      ]],
      ['safe-to-merge', 60, 'a short merge question', [
        'Is my change safe to merge?',
        'Would you merge this diff as it stands?',
      ]],
      ['concurrency-and-errors', 60, 'names the focus areas without the word "review"', [
        'Check my change for data races and TCA misuse.',
        'Go through the diff looking for concurrency bugs, bad error handling and API problems.',
      ]],
      ['after-gate-green', 40, 'follows a green gate, as the description says', [
        'The tests pass on my branch. Do a code review before I send it to a human.',
        'The gate is green. Now critique the code on this branch.',
      ]],
      ['main-vs-head', 40, 'names the diff range', [
        'PR review please: current branch against main.',
        'Please review the diff between main and HEAD.',
      ]],
    ],
    near: [
      ['review-sync-design', 'design', 60, 'shares "review"; the object is a design', [
        'Review the design for offline sync before we commit to building it.',
        'I have a proposed design for offline sync. Take it through review and approval.',
      ]],
      ['review-my-tests', 'test-gate', 60, 'shares "review"; the object is the tests', [
        'Review my tests. Are they real, or slop?',
        'Look at the tests on this branch and tell me whether any of them are fake.',
      ]],
      ['review-staged-comments', 'comment-audit', 60, 'shares "review"; the object is the comments', [
        'Review the comments in my staged change.',
        'Go through the comments I\'m about to commit and tell me which to keep, trim or cut.',
      ]],
      ['review-doc-wording', 'prose', 40, 'shares "review"; the object is markdown prose', [
        'Review the wording in docs/overview.md and make it plain English.',
        'Proofread this repo\'s README and tighten the prose.',
      ]],
      ['human-review-tips', 'none', 40, 'shares "review"; asks for general advice', [
        'What does a good checklist for reviewing Swift pull requests look like? General advice, please.',
        'Give me tips for reviewing SwiftUI PRs as a human reviewer.',
      ]],
    ],
  },
  'test-gate': {
    should: [
      ['full-gate-before-ready', 60, 'asks to gate the branch', [
        'Is this ready? Run the full gate on my branch.',
        'Gate this branch before I mark the PR ready.',
      ]],
      ['tests-catch-regressions', 60, 'asks whether new tests are real', [
        'Check that the tests I wrote are real and not just padding.',
        'Before I push, make sure my new tests would actually catch a regression.',
      ]],
      ['after-tdd-cycle', 60, 'follows a finished TDD change', [
        'I finished the TDD cycle for the counter fix. What has to pass before I open the PR? Run it.',
        'Done implementing, and the unit tests are green. Run everything that must pass before I mark it ready.',
      ]],
      ['heavy-tiers', 40, 'names the heavy checks', [
        'Run the heavy checks on this change: the flows, stress and prove.',
        'Run the push and ready tiers on my diff.',
      ]],
      ['can-i-open-pr', 40, 'a readiness question before review', [
        'Can I open the PR now? Make sure all the gates pass and the tests hold up.',
        'Before I ask for review, make sure everything passes and the tests aren\'t junk.',
      ]],
    ],
    near: [
      ['write-increment-test', 'tdd', 60, 'shares "test"; asks to write one', [
        'Write a test for the counter reducer\'s increment action.',
        'Add a unit test that covers decrement in CounterFeature.',
      ]],
      ['pr-testing-section', 'validate', 60, 'shares "tested" and "PR"; asks for evidence text', [
        'Write the testing section of my PR description.',
        'Give me paste-ready evidence of what was tested, for the PR body.',
      ]],
      ['merge-verdict-code', 'review', 60, 'shares "ready"; asks about the code, not the tests', [
        'Is this mergeable? I want a verdict on the code itself, not the tests.',
        'Code-review my branch and give me a merge verdict.',
      ]],
      ['filter-one-test', 'none', 40, 'shares "run the tests"; a how-to question', [
        'How do I run a single Swift Testing test from the command line?',
        'What\'s the swift test flag for running just one test?',
      ]],
      ['flaky-engine-test', 'tdd', 40, 'shares "tests"; asks to fix one', [
        'A test in GameEngineTests is flaky. Make it deterministic.',
        'GameEngineTests sometimes fails at random. Fix the test so it\'s stable.',
      ]],
    ],
  },
  validate: {
    should: [
      ['how-this-was-tested', 60, 'asks for the PR testing section', [
        'Fill in the "How this was tested" part of my PR.',
        'Write the testing section for my pull request.',
      ]],
      ['prove-ready-paste', 60, 'asks for proof to paste into the PR', [
        'Prove this change is ready for review, and give me something to paste into the PR.',
        'I need evidence for the PR that this works: verdicts, test counts and timings.',
      ]],
      ['validate-branch', 60, 'the bare command word', [
        'Validate this branch.',
        'Please validate my change.',
      ]],
      ['evidence-before-ready', 40, 'about to mark the PR ready', [
        'I\'m about to mark the PR ready. Produce the evidence block.',
        'Generate the PR body section that shows what ran and what didn\'t.',
      ]],
      ['reviewer-wants-proof', 40, 'a reviewer asks for proof', [
        'My reviewer wants proof the tests ran. Put the evidence together.',
        'Give me a summary of the test results I can paste into the PR for my reviewer.',
      ]],
    ],
    near: [
      ['toml-syntax', 'none', 60, 'shares "validate"; asks about file syntax', [
        'Validate that .swiftgate.toml is well-formed TOML. Just check the syntax.',
        'Does the .swiftgate.toml file parse? Only check its syntax.',
      ]],
      ['cap-count-input', 'tdd', 60, 'shares "validate"; a behaviour change', [
        'Add input validation so the counter can never go above 100.',
        'Validate the count in the reducer: cap it at 100.',
      ]],
      ['review-before-pr', 'review', 60, 'shares "before I open the PR"; asks for a code review', [
        'Before I open the PR, review the code for problems.',
        'Give the change a code review so I know it\'s mergeable before I open a PR.',
      ]],
      ['tests-not-slop-before-pr', 'test-gate', 40, 'shares "before I open the PR"; asks to judge tests', [
        'Before I open the PR, check that my new tests aren\'t slop.',
        'Make sure the tests in this PR don\'t pass trivially before I open it.',
      ]],
      ['where-did-i-leave-off', 'status', 40, 'shares "ready" and "plans"; asks for status', [
        'Where did I leave off? Which plans are still active?',
        'What was I working on across my repos?',
      ]],
    ],
  },
  'comment-audit': {
    should: [
      ['comments-worth-keeping', 60, 'asks which comments to keep', [
        'Go through the comments in my change and tell me which are worth keeping.',
        'Are the comments I added actually useful? Suggest which to cut.',
      ]],
      ['clean-up-before-commit', 60, 'asks to clean up before a commit', [
        'Clean up the comment noise before I commit.',
        'There are too many comments in my diff. Trim them before the commit.',
      ]],
      ['ai-written-comments', 60, 'names the AI as the author', [
        'Claude added a lot of comments in the last change. Audit them.',
        'Look at the AI-written comments in my staged files: keep, trim or cut each one?',
      ]],
      ['restate-the-code', 40, 'asks whether comments restate code', [
        'Do my staged comments tell me anything the code doesn\'t?',
        'Check whether the comments I\'m about to commit just restate the code.',
      ]],
      ['counter-change-comments', 40, 'names a specific change', [
        'Help me decide which comments in the counter change to delete.',
        'Tidy up the doc comments on the new reducer code before I commit.',
      ]],
    ],
    near: [
      ['document-api-client', 'none', 60, 'shares "comments"; asks to write them', [
        'Add doc comments to the public API of APIClient.',
        'Document the public functions in APIClient with /// comments.',
      ]],
      ['tighten-doc-prose', 'prose', 60, 'shares "trim"; the object is markdown prose', [
        'Trim the wordy prose in docs/overview.md.',
        'Make this repo\'s README read in plain English.',
      ]],
      ['full-branch-review', 'review', 60, 'shares "review my change"; asks for a full review', [
        'Review my whole change, not just the comments. Is it mergeable?',
        'Do a full code review on this branch, please.',
      ]],
      ['doc-comment-syntax', 'none', 40, 'shares "doc comment"; a syntax question', [
        'What\'s the Swift syntax for a documentation comment with a parameter list?',
        'How do I write a /// comment with a - Parameters: section in Swift?',
      ]],
      ['remove-commented-out-code', 'none', 40, 'shares "comments"; asks to delete dead code', [
        'Remove the commented-out code in CounterView.swift.',
        'Delete the dead, commented-out lines in the counter view.',
      ]],
    ],
  },
}

// Round 2 adds tuning requests in the shapes round 1's held-out set found and its tuning set
// lacked: fixing a failing or flaky test for tdd, judging whether tests are real for test-gate.
const round2 = {
  tdd: {
    should: [
      ['red-after-refactor', 60, 'a test went red after a refactor', [
        'I refactored the HTTPClient retry code and now a test is red. Get it passing again.',
        'After my cleanup in HTTPClient, one of its tests fails. Make it pass.',
      ]],
      ['flaky-counter-test', 60, 'an intermittent test failure', [
        'CounterFeatureTests fails maybe one run in five. Make it reliable.',
        'There\'s a flaky test in the counter tests. Stop it failing at random.',
      ]],
      ['broken-snapshot-test', 60, 'a snapshot test broke after a UI change', [
        'The counter snapshot test broke after I changed the button colour. Fix it.',
        'CounterView\'s snapshot test has been failing since the colour change. Sort it out.',
      ]],
    ],
    near: [
      ['where-is-decrement-tested', 'none', 60, 'shares "tests"; asks where a test lives', [
        'Which tests cover the decrement action? Just point me to them.',
        'Show me where decrement is tested.',
      ]],
      ['would-tests-catch-anything', 'test-gate', 60, 'shares "tests"; asks whether tests are real', [
        'Do the tests on this branch actually catch anything, or would they pass no matter what?',
        'Tell me if any test in my change is fake.',
      ]],
    ],
  },
  'test-gate': {
    should: [
      ['tests-pulling-weight', 60, 'asks whether the change\'s tests are real', [
        'Would the tests in my change fail if the code were wrong?',
        'Are the new tests in this change pulling their weight, or are they padding?',
      ]],
      ['flip-to-ready', 60, 'about to mark the PR ready', [
        'I\'m about to flip the PR to ready. Check the tests hold up first.',
        'The PR goes to ready in a minute. Make sure the test side is solid.',
      ]],
    ],
    near: [
      ['make-red-test-green', 'tdd', 60, 'shares "test" and "branch"; asks to fix one', [
        'One test on my branch is red. Fix it so it passes.',
        'My branch has a failing test. Make it green.',
      ]],
      ['impact-wants-a-test', 'tdd', 60, 'shares the gate\'s words; asks to write the test', [
        'The impact check says CounterCore changed without a test. Add the test.',
        'swiftgate impact wants a test for my CounterCore change. Write it.',
      ]],
    ],
  },
}

// Round 3 tunes test-gate on requests that ask only for a judgment of the tests: no PR, no gate,
// nothing to run. Round 2's independent held-out set found that shape, and no tuning set had it.
const round3 = {
  'test-gate': {
    should: [
      ['r3t-wrong-state-still-passes', 60, 'asks which tests pass on a wrong reducer', [
        'Go through the tests I added and tell me which would still pass if the reducer returned the wrong state.',
        'Do my new tests assert anything that matters? Read them and tell me.',
      ]],
      ['r3t-grade-the-tests', 60, 'asks for a grade of the change\'s tests', [
        'Rate the tests in my change: real coverage or decoration?',
        'Give the tests on this branch an honest grade. Are they worth keeping?',
      ]],
      ['r3t-test-smells', 60, 'asks for test smells the tools miss', [
        'Look for test smells in what I added: over-mocking, testing internals, that kind of thing.',
        'Check my new tests for coupling to implementation details or too many stubs.',
      ]],
    ],
    near: [
      ['r3t-add-missing-assertion', 'tdd', 60, 'shares "assert"; asks to change a test', [
        'My dismiss test doesn\'t check that the fact is gone. Add that assertion.',
        'Make the dismiss test assert that the fact becomes nil.',
      ]],
      ['r3t-hollow-test-meaning', 'none', 60, 'shares "hollow"; asks a general question', [
        'What makes a unit test hollow? A general answer, not about this repo.',
        'Explain what people mean by tests that only pad coverage.',
      ]],
      ['r3t-summarise-tests-for-pr', 'validate', 60, 'shares "tests"; asks for PR text', [
        'Summarise what the tests on this branch cover, for the PR description.',
        'Write up the tests I added as the testing notes in my pull request.',
      ]],
    ],
  },
}

// Held-out and extra request sets that independent agents wrote from the skill descriptions and
// the app alone, so the person tuning the skills didn't write them. A file without splits is
// held out whole.
const here = dirname(fileURLToPath(import.meta.url))
const external = (file) => (existsSync(join(here, file)) ? JSON.parse(readFileSync(join(here, file), 'utf8')) : {})
const heldOut2 = external('routing_heldout_r2.json')
const heldOut3 = external('routing_heldout_r3.json')
const fiveSkills = external('routing_five_skills.json')

// Round 5 tunes review and validate on the shapes rounds 2 and 3 found in held-out sets: a merge
// or approval verdict that says to leave the tests aside, and a request to summarise a change's
// tests for the PR description.
const round5 = {
  review: {
    should: [
      ['r5t-approve-or-not', 60, 'asks for an approval verdict on the change', [
        'Would you approve this change if it landed in your review queue?',
        'yes or no, would you sign off on my branch as it stands',
      ]],
      ['r5t-merge-ignore-tests', 60, 'merge verdict on the code, tests explicitly out of scope', [
        'Leave the tests out of it. Is the reducer code on this branch good enough to merge?',
        'dont care about the tests rn, just tell me if the production code here is mergeable',
      ]],
      ['r5t-blocking-issues', 60, 'asks what would block the merge', [
        'What would stop you from merging my fact-dismiss branch?',
        'anything blocking on this diff before it goes in?',
      ]],
    ],
    near: [
      ['r5t-judge-new-tests-only', 'test-gate', 60, 'judges only the tests, no merge verdict', [
        'Forget the reducer. Are the tests I added on this branch real, or would they pass on broken code?',
        'just the tests on my branch: do they actually catch anything',
      ]],
      ['r5t-explain-diff', 'none', 60, 'wants an explanation of the change, no verdict', [
        'Walk me through what the fact-dismiss commit changes, in plain terms. No verdict needed.',
        'summarize what my branch changes for me, just a description',
      ]],
    ],
  },
  validate: {
    should: [
      ['r5t-summarise-tests-for-pr', 60, 'asks for the tests summarised for the PR description', [
        'Summarise the tests on this branch so I can paste them into the PR description.',
        'give me a short tests-run blurb for my PR body',
      ]],
      ['r5t-how-verified-section', 60, 'asks for the how-it-was-verified section', [
        'Draft the "How was this verified" part of my pull request from what actually ran.',
        'need the verification section for the PR, based on real test results',
      ]],
    ],
    near: [
      ['r5t-write-pr-title', 'none', 60, 'PR text with no testing evidence', [
        'Suggest a good title for my pull request about dismissing facts.',
        'pr title for the fact dismiss change?',
      ]],
      ['r5t-are-tests-enough-for-pr', 'test-gate', 60, 'judges whether the tests are real before the PR', [
        'Before I write up the PR, are the tests I added strong enough to trust, or are some hollow?',
        'are my new tests legit before i open the pr, or padding',
      ]],
    ],
  },
}
const heldOut5 = external('routing_heldout_r5.json')

// Round 6 tunes the ship and build skills, which rounds 1 to 5 predate: taking a spec to merged
// code in one command, and building an existing plan's ledger.
const round6 = {
  ship: {
    should: [
      ['r6t-ship-readme', 60, 'wants a spec taken to merged code in one go', [
        'Here is specs/favorites.md. Take it all the way to merged, green code.',
        'ship specs/favorites.md end to end',
      ]],
      ['r6t-interview-preset', 60, 'names the interview preset for a spec', [
        'Run the offline-sync README through the whole pipeline with the interview preset and tell me how long it took.',
        'interview preset on docs/offline-sync-README.md, full run please',
      ]],
    ],
    near: [
      ['r6t-release-notes', 'none', 60, 'shipping in the release sense, no harness work', [
        'Write release notes for what we are shipping this week.',
        'draft this weeks release notes',
      ]],
      ['r6t-spec-to-design-only', 'design', 60, 'a spec, but only a design doc is wanted', [
        'Turn specs/favorites.md into a design doc for review. Stop after the design; no plan or code.',
        'just design specs/favorites.md, dont build anything yet',
      ]],
    ],
  },
  build: {
    should: [
      ['r6t-build-the-plan', 60, 'an approved, planned ledger to build', [
        'The fact-cache plan is approved and its ledger is ready. Start building it.',
        'kick off the build for the fact-cache plan',
      ]],
      ['r6t-continue-build', 60, 'resume building remaining ledger tasks', [
        'Main is green again. Continue building the remaining tasks in the fact-cache plan.',
        'resume the fact-cache build, main is fixed',
      ]],
    ],
    near: [
      ['r6t-build-compiles', 'none', 60, 'build in the compile sense', [
        'Does the project build cleanly for the simulator right now? Just check.',
        'does it compile rn',
      ]],
      ['r6t-build-one-reducer-change', 'tdd', 60, 'build one small behavior change', [
        'Build a reset action into CounterFeature that sets the count back to zero.',
        'add a reset action to the counter reducer',
      ]],
    ],
  },
}
const heldOut6 = external('routing_heldout_r6.json')

const PROMPT_FRONTMATTER = `---
runs: 3
max_turns: 1
timeout_seconds: 300
allowed_tools: [Read, Glob, Grep, Skill]
---
`

const skillMatch = (skill) => `"\\"skill\\":\\"swift-harness:${skill}\\""`
const grader = (fields, body = '') =>
  `---\n${Object.entries(fields).map(([k, v]) => `${k}: ${v}`).join('\n')}\n---\n${body}`

// The held-out file omits the split, since every request in it is held out.
const withSplit = (table, split) => Object.fromEntries(Object.entries(table).map(([skill, { should, near }]) => [skill, {
  should: should.map(([slug, why, p]) => [slug, split, why, p]),
  near: near.map(([slug, expect, why, p]) => [slug, expect, split, why, p]),
}]))

export function expand() {
  const out = []
  const tables = [[requests, 1], [round2, 2], [withSplit(heldOut2, 40), 2], [round3, 3], [withSplit(heldOut3, 40), 3], [fiveSkills, 4], [round5, 5], [withSplit(heldOut5, 40), 5], [round6, 6], [withSplit(heldOut6, 40), 6]]
  const seen = new Set()
  for (const [table, round] of tables) {
    for (const [skill, { should, near }] of Object.entries(table)) {
      const add = (c) => {
        const key = `${skill}/${c.slug}`
        if (c.variant === 'a' && seen.has(key)) throw new Error(`${key}: duplicate slug`)
        seen.add(key)
        out.push({ skill, round, ...c })
      }
      for (const [slug, split, why, phrasings] of should) {
        phrasings.forEach((prompt, i) => add({ slug, kind: 'should-trigger', expect: skill, split, why, prompt, variant: 'ab'[i] }))
      }
      for (const [slug, expect, split, why, phrasings] of near) {
        if (expect === skill) throw new Error(`${skill}/${slug}: a near-miss can't expect its own skill`)
        phrasings.forEach((prompt, i) => add({ slug, kind: 'near-miss', expect, split, why, prompt, variant: 'ab'[i] }))
      }
    }
  }
  return out
}

function graders(c) {
  if (c.kind === 'should-trigger') {
    return { [`loads-${c.skill}.md`]: grader({ type: 'tool_used', tool: 'Skill', input_match: skillMatch(c.skill), min: 1 }) }
  }
  const files = {
    [`skips-${c.skill}.md`]: grader({ type: 'tool_used', tool: 'Skill', input_match: skillMatch(c.skill), min: 0, max: 0 }),
  }
  if (c.expect === 'none') {
    files['loads-no-harness-skill.md'] = grader({
      type: 'tool_used', tool: 'Skill', input_match: `"\\"skill\\":\\"swift-harness:"`, min: 0, max: 0,
    })
  } else {
    files[`loads-${c.expect}.md`] = grader({ type: 'tool_used', tool: 'Skill', input_match: skillMatch(c.expect), min: 1 })
  }
  return files
}

function write(c) {
  const name = `${c.slug}-${c.variant}`
  const dir = join(cases, c.skill, name)
  rmSync(dir, { recursive: true, force: true })
  mkdirSync(join(dir, 'graders'), { recursive: true })
  const role = c.kind === 'should-trigger'
    ? `Should-trigger case for ${c.skill}`
    : `Near-miss case for ${c.skill}; ${c.expect === 'none' ? 'no harness skill' : c.expect} should load instead`
  const yaml = [
    'schema_version: "1.1"',
    `name: routing-${c.skill}-${name}`,
    'description: >',
    `  ${role}. It tests routing on a request that ${c.why}. Paraphrase ${c.variant} of`,
    `  ${c.slug}. Source: suites.md skill-routing. Generated by evals/runner/seed_routing.mjs.`,
    `tags: [routing, ${SUITE_TAG}, for-${c.skill}, ${c.kind}, split-${c.split}, load-${c.expect}, round-${c.round}]`,
    `expected_outcome: ${c.expect === 'none' ? 'No swift-harness skill loads.' : `The Skill tool loads swift-harness:${c.expect}.`}`,
    'context:',
    '  scaffold_script: scaffold.sh',
    '',
  ].join('\n')
  writeFileSync(join(dir, 'case.yaml'), yaml)
  writeFileSync(join(dir, 'prompt.md'), `${PROMPT_FRONTMATTER}\n${c.prompt}\n`)
  for (const [file, text] of Object.entries(graders(c))) writeFileSync(join(dir, 'graders', file), text)
  // The runner refuses a scaffold path outside the case, so each case links the shared one.
  symlinkSync('../../../../scaffold/sampleapp-with-change.sh', join(dir, 'scaffold.sh'))
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const all = expand()
  for (const c of all) write(c)
  const count = (split) => all.filter((c) => c.split === split).length
  console.log(`wrote ${all.length} cases: ${count(60)} in split-60, ${count(40)} in split-40`)
}
