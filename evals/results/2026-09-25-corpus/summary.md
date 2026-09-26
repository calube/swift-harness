# Rule corpora, 2026-09-25

The first `checker-accuracy` corpora for `prose`, the `det.*` lint rules and the `arch.*` rules.
They make no model calls. Cases come from `evals/runner/seed_corpora.mjs`, which writes each
label along with its seed. `evals/runner/corpus.mjs` scores `swiftgate --json` rule ids against
those labels. Per-case results are in `corpus.md` and `corpus.json`.

## Pins

| Pin | Value |
|---|---|
| swiftgate | 0.1.0, built from `gate/` at `0c53f13` |
| Harness commit | `0c53f13` |
| Xcode | 26.2, Swift 6.2.3 |
| Cost | 0 USD; about 90 s wall for all 104 cases |

## Headline

| Gate | Cases | Match labels | Positive recall | Near-miss and clean false positives |
|---|---|---|---|---|
| `prose` | 36 (12 positive, 6 evasion, 17 near-miss, 1 clean) | 26 | 12/12 | 6 of 18 cases |
| `lint`, `det.*` | 41 (21, 7, 12, 1) | 36 | 21/21 | 0 of 13 |
| `arch.*` | 27 (14, 4, 8, 1) | 25 | 13/14 | 0 of 9 |

Every mechanical rule in scope reaches recall 1.0 on its planted positives except
`arch.engine-replay-test`, at 0 of 1. The clean corpora (the `SampleApp` baseline and the
`evals/` docs) have 0 findings.

## Error analysis

1 line per failing case, grouped by cause:

| Cause | Cases | Layer | Action |
|---|---|---|---|
| The prose rules can't tell a quoted phrase from its use | `quoted-mention-filler`, `quoted-mention-adverb` | gate | propose: skip text inside double quotes, or document the limit |
| The filler list includes `just`, which often carries meaning ("only", "a moment ago") | `just-meaning-only`, `just-meaning-recently` | gate | propose: drop `just` from the list or narrow it |
| `number-word` flags a pronoun "one" and a number word that starts a sentence | `one-as-pronoun`, `number-sentence-start` | gate | propose: extend the pronoun context; exempt sentence starts |
| `arch.engine-replay-test` only checks for "replay" in a test name. SampleApp passes on incidental wording ("recorded replays", "reset replaying") after its real replay test is removed | `engine-without-replay-test`, `engine-replay-named-only` | gate | the limit is documented in the rule. Propose: drop the display-name match, or require a function name |
| Evasions the rules don't see | `date-typealias-core`, `date-init-reference-core`, `cf-absolute-time-core`, `nsuuid-core`, `continuous-clock-sleep-core`, `en-dash-spaced`, `jargon-inflected`, `passive-get`, `passive-unlisted-participle` | gate | no bar yet: each needs a rule, a documented limit or a `wontfix` |

The `docs/` audit backs up the prose causes. In a random sample of 46 of the 285 prose findings
over the docs that predate the rule (up to 8 per rule), the operator labelled 7 as false positives.
By rule: filler 4 of 6, number-word 2 of 8, adverb 1 of 8, and 0 of 8 for em-dash, passive voice
and sentence length. Labels are in `prose-audit.json`. They need a person to confirm them before anyone relies
on the rates.

## Checks on the evals

| Check | Result |
|---|---|
| Graders tell good from bad | `corpus_test.mjs` fails under 4 planted runner bugs: an unlabelled finding passing a case, a recalled rule counted as a false positive, a missed rule counted as recalled, a near-miss with expected findings loading |
| Failures trace to real causes | the first run had 12 mismatches. 5 traced to the cases (a planted `two` in a jargon seed, a test-plan bullet not in the canonical form, a dependency cycle, an undeclared vendor package, an undeclared test-support module). After the fixes, every remaining mismatch traces to the gate |
| Evals catch a broken harness | `--drop-rule` on `det.date-init`, `arch.live-dependency` and `prose.passive-voice` each dropped that rule's recall to 0 and made `--check` exit 1 |
| Results hold still | 3 full runs gave the same verdict per case. The corpora are deterministic |
| Coverage | the 5 `det.*` rules, 10 `arch.*` rules and 7 prose rules each have at least 1 positive and 1 near-miss. `docs-lint`, `design-lint`, `plan-lint`, `evidence check`, `comments`, `testlint` and the other lint families have no corpus yet |

## Labels that need a person

`number-sentence-start` and the 5 `wild` near-misses carry `"labelledBy": "operator; needs a person
to confirm"` in their `labels.json`, as do the audit labels.

## Harness defects found

| Defect | Evidence |
|---|---|
| `prose.filler` flags meaning-bearing `just` and quoted mentions; 4 of 6 sampled filler findings on `docs/` are false positives | `just-meaning-*`, `quoted-mention-filler`, `prose-audit.json` |
| `prose.adverb` flags a quoted mention | `quoted-mention-adverb` |
| `prose.number-word` flags the pronoun "one" and sentence-initial number words | `one-as-pronoun`, `number-sentence-start` |
| `arch.engine-replay-test` passes an engine whose only "replay" is in unrelated test names | `engine-without-replay-test` on SampleApp |
| `docs/standards.md` C5 says "Enforced by: review", but `arch.core-main-actor-isolation` enforces it | the rule id index lists the rule; `main-actor-default-core` trips it |
