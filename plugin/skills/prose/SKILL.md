---
name: prose
description: This skill should be used whenever Claude writes or edits running prose in a markdown file this harness gates, such as a design doc, an ADR, a plan or a doc under docs/. It teaches the plain-English rules that `swiftgate prose` enforces (adverbs, em-dashes, number words, passive voice, filler, jargon, sentence length) with a fix and a before/after for each, so a draft passes the gate on the first run. Use it before running `swiftgate design-lint`, when the drafter reaches its prose pass, when `swiftgate prose` or `design-lint` reports a `prose.*` finding, or when the user asks to "tighten the prose", "make this plain English" or "fix the prose findings".
---

# Prose

`swiftgate prose` checks running prose against 7 mechanical rules. This skill teaches those rules
so you write to them, and the gate confirms you did. The gate decides. The skill and the gate list
the same rule ids, and a test in the gate fails if they drift apart.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`.

## When to apply it

1. Draft the section.
2. Apply every rule below to what you wrote.
3. Run `"$SG" prose <file>` to confirm. Add `--json` for a `RunReport`.
4. Then run `"$SG" design-lint <doc>` for a design doc. It runs the same prose rules with its own
   checks, so a clean prose pass keeps its report short.

Exit codes: `0` clean, `1` at least 1 finding, `2` an unreadable file or no file given.

Don't argue with a finding. Each rule is a fixed heuristic with no suppression, so the way past a
finding is a better sentence. Rewrite it, rerun, and move on. Don't hide prose from the check by
wrapping plain words in backticks or moving them into a table.

## What the gate reads

It reads running prose: paragraphs, list items and headings. It skips fenced code, inline code,
tables, Mermaid diagrams, HTML comments and frontmatter. Put a real identifier, command or quoted
bad example in code, where it belongs anyway. A sentence never crosses a block, so each list item
and each heading counts on its own.

## The rules

Every finding is `major` and names the rule, the line and the words that tripped it.

### `prose.adverb`

Flags a word ending in `-ly` of 4 letters or more. A list of `-ly` words that aren't adverbs is
exempt (`only`, `early`, `daily`, `likely`, `apply`), and so is a capitalized word in mid-sentence.

Fix: cut the adverb, or swap the verb and adverb for a stronger verb or a measured fact.

- Before: `The check runs quickly and reports clearly.`
- After: `The check runs in 2 seconds and names the failing line.`

### `prose.em-dash`

Flags an em-dash character, or `--` standing alone between spaces. The test plan's tier tail is
the one exception: in a bullet that starts with `test-`, the ` — tier T<n>` at the end is syntax.

Fix: use a comma, a colon, parentheses or 2 sentences.

- Before: `The lock is per plan — a second session can't take it.`
- After: `The lock is per plan. A second session can't take it.`

### `prose.number-word`

Flags a number word from `zero` to `billion` that counts the next word. It lets these pass: a
hyphenated form (`one-off`), a phrase like `one of` or `two or three`, and `one` as a pronoun
(`the one that`, `one by one`).

Fix: use the numeral.

- Before: `The review runs three agents over two passes.`
- After: `The review runs 3 agents over 2 passes.`

### `prose.passive-voice`

Flags a form of `be`, an optional modifier such as `not` or an adverb, then a participle: a word
ending in `-ed` or an irregular participle from a list, like `built`, `run` or `written`. State words
(`closed`, `limited`, `deprecated`) and `un…ed` words (`unchanged`) pass. The heuristic misses a
`get` passive and an unlisted irregular participle, so don't count on the miss.

Fix: name who acts and make it the subject.

- Before: `The ledger is updated after each wave.`
- After: `The orchestrator updates the ledger after each wave.`

### `prose.filler`

Flags words and phrases that add length and no meaning, from a fixed list. The list includes
`very`, `really`, `quite`, `just`, `simply`, `basically`, `actually`, `in order to`,
`the fact that`, `in terms of`, `a number of`, `it's worth noting` and `of course`.

Fix: cut it. If the sentence breaks, rebuild it around the verb.

- Before: `In order to run the probe, you just need a scratch package.`
- After: `To run the probe, you need a scratch package.`

### `prose.jargon`

Flags business jargon from a fixed list, such as `leverage`, `utilize`, `seamless`, `streamline`,
`actionable`, `holistic`, `going forward`, `deep dive` and `low-hanging fruit`.

Fix: say what the thing does in plain words.

- Before: `We leverage the cache to streamline reruns.`
- After: `Reruns read the cache and skip the build.`

### `prose.sentence-length`

Flags a sentence longer than the ceiling. The ceiling defaults to 40 words, and a repository
sets its own with `[docs] sentence_ceiling` in `.swiftgate.toml`. A sentence ends at `.`, `!` or
`?` followed by a space and then a capital, a digit or inline code.

Fix: split at the natural joint, often an `and`, a `which` or a semicolon. Put a list of 3 or more
items in bullets.

- Before: `The design skill claims the plan at frame, asks the user the frame questions, drafts each section from the research lanes, runs the prose pass and design-lint over the draft, sends it to the review agents, and publishes once review returns ready.`
- After: `The design skill claims the plan at frame and asks the frame questions. It drafts each section from the research lanes. It runs the prose pass and design-lint, then sends the draft to review. It publishes once review returns ready.`

## Word lists

The lists live in the gate as constants, and only the sentence ceiling is configurable. When a
finding surprises you, trust the gate's message over your memory of these examples.
