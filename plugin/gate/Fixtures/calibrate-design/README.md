# Design agent calibration seeds

`swiftgate calibrate design` runs every design agent against the labelled cases in this
directory (spec §12, layer 2). Cases are hand-authored and labelled by construction: the author
builds the input so the correct answer is known, for example an overstated claim next to the
genuine quote.

## Layout

```
gate/Fixtures/calibrate-design/
  README.md
  last-pass.json                 written by a full pass; committed
  <agent>/                       named after agents/<agent>.md; must match design-*
    <case>/                      any directory name; one case
      input.md                   the case the agent receives, verbatim
      label.json                 the questions and the answer a correct agent gives
```

- Every `<agent>` directory needs an `agents/<agent>.md` whose name starts with `design-`.
  Otherwise the run exits 1 with `calibrate-design.unknown-agent`.
- Every `agents/design-*.md` needs at least one case, or the run exits 1 with
  `calibrate-design.uncalibrated-agent`.
- A case directory with no `label.json` exits 1 with `calibrate-design.missing-label` naming
  the case. A case with no `input.md` exits 1 with `calibrate-design.missing-input`.
- Files and dot-entries directly under this directory or an agent directory are ignored.

## The seeds

Each case plants one defect, and the label fixes what the agent's own prompt requires it to
return. Each defect has a clean twin: the same case with the defect removed, where the agent must not flag it.
The spec's layer 2 seeds come first; the rest give every other design agent a case.

| Agent | Defect case: expected answer | Clean twin: expected answer |
|---|---|---|
| `design-claim-checker` | `overstated-claim`: a genuine quote under a claim that says "always": `refuted` | `genuine-quote`: the same quote, a claim that says only what it shows: `supported` |
| `design-evidence-auditor` | `decision-contradicts-evidence`: the Decision says queued orders survive termination, citing a claim that they live in memory only: gating, at `decision`, `blocker` | `decision-follows-evidence`: the Decision claims only in-session retry: no gating finding at `decision` |
| `design-evidence-auditor` | `option-on-probe-refuted-api`: the chosen option cites a claim whose probe failed: gating, at `decision`, `blocker` | as above |
| `design-standards-conformance` | `uikit-in-core-module`: a Core module imports UIKit: gating, rule `A2` | `uikit-in-live-module-only`: UIKit sits behind a client in its `*Live` module: no gating finding citing `A2` |
| `design-challenger` | `option-on-probe-refuted-api`: the chosen option rests on an API the probe refuted: a gating finding says an API it calls failed its probe, at any anchor | `option-on-probe-passed-api`: the chosen option's APIs all passed their probes: no gating finding says one failed |
| `design-pre-mortem` | `unbounded-prefetch`: one download per album photo, all at once: gating, at `decision` or `perf--scale`, and its story has downloads grow with the album | `bounded-prefetch`: at most 6 in flight, tested: no gating story has downloads grow with the album |
| `design-drafter` | `point-without-supported-claim`: a frame answer no supported claim backs: `[UNVERIFIED]`, repeated in Risks or Open questions | `point-with-supported-claim`: the pack holds a claim that backs it: cite it |
| `design-decomposer` | `flow-test-needs-ready-gate`: a T3 test: gate `ready` | `host-test-needs-fast-gate`: a T1 test: gate `fast` |
| `design-lane-codebase` | `product-intent-question`: the brief asks a product choice: `needsDecision` | `code-fact-question`: the brief asks what code does: a `file` claim |
| `design-lane-apple-docs` | `signature-needs-probe`: a snapshot shows a signature: a `probe` claim | `semantics-from-snapshot`: the snapshot states behaviour: a `snapshot` claim |
| `design-lane-packages` | `pinned-package-not-checked-out`: the pinned package has no checkout: `needsDecision` | `pinned-package-checked-out`: a claim citing the checkout, pinned `<pkg>@<version>` |
| `design-lane-prior-decisions` | `refuted-prior-claim`: a prior claim was refuted: a warning claim citing the refuted claim's record | `supported-prior-file-claim`: carried forward with its original id, status `new` |

These seeds each held a choice a careful agent could make either way, so each is built to leave
one answer:

- `design-standards-conformance/uikit-in-core-module` scored D2 against the label A2 at p≈0.55
  when its pack carried D2 and D3, the client rules, whose text names UIKit. The design declares
  no client module, and a real standards pack holds only the rules for the module kinds in
  scope, so the seed carries A2, A5 and P9 only. The label requires a gating finding citing A2
  and doesn't ask for it to be the only one, so an extra D2 finding is not a miss.
- `design-lane-codebase/product-intent-question` covered its brief with `needs-decision` at
  p=0.6 over `claim` when the label asked for one of the two. A codebase lane may back its
  question with a claim about the code it read, and its contract asks for that (`"evidence"`
  lists claim ids), so the two were never exclusive. The label requires a `needsDecision` entry
  and says nothing about claims.
- `design-drafter/*` carry no claim about `earliestBeginDate`. With one, the drafter can restate
  the frame's "every 15 minutes" as a supported "no sooner than 15 minutes", which is a better
  doc and dodges the point the case plants.
- `design-evidence-auditor/decision-*` carry no claim that the queue sends one order at a time.
  Its quote showed one awaited call under a code comment, so the auditor rightly found a gating
  overreach in the clean twin, which has nothing to do with the planted defect.
- `design-lane-prior-decisions/refuted-prior-claim` needs a `file` claim citing the earlier
  design, and a `file` loc needs a line range. Without line-numbered excerpts of `book-cache.md`
  and its claims record, a careful agent returns no claim rather than invent a range, so the
  seed carries both, as the codebase seeds carry their source lines.
- `design-challenger/option-on-probe-passed-api` states when the live client starts and cancels
  its monitor, with passing probes for those APIs. Without that, opus rightly found the
  unspecified lifecycle a major gap and placed it at `decision` in 2 of 3 runs, which has
  nothing to do with the probe verdicts the pair plants.
- `design-lane-prior-decisions/refuted-prior-claim` requires a `file` claim citing the refuted
  claim's record, `book-cache.evidence/claims.jsonl` from line 4 (label changed with the user's
  approval, 2026-09-30). Any claim citing `book-cache.` met the old label, so a lane that cited
  only the design's `book-cache.md:L9` sentence passed without warning that the claim was refuted.
- `design-challenger/*` are judged on what the gating findings say about the chosen option's
  probe verdicts, at any anchor (label changed with the user's approval, 2026-09-30). The old
  label asked for a gating finding at `decision`, so it scored where opus filed a finding rather
  than the planted failed `pathUpdates` probe: a lifecycle gap filed at `decision` failed the
  clean twin, and the refuted twin's probe finding filed elsewhere would have failed it too.
- `design-pre-mortem/*` are judged on what the gating failure stories say about concurrent
  downloads. A pre-mortem is asked to find every open failure story, and the clean twin leaves
  some open (failed downloads, cache retention), so "no gating finding" isn't its label.
- `design-lane-prior-decisions/supported-prior-file-claim` carries a prior claim whose text says
  no more than its quote: DatabaseWriter.swift documents that it executes database operations
  in a transaction (seed changed with the user's approval, 2026-10-04). The old text said
  `DatabaseQueue.write` runs its closure inside one transaction, broader than the quote, so the
  lane prompt's rule to carry a prior claim verbatim under its id met its rules that a claim say
  no more than its quote and that a different claim takes a new id, and the clean twin had two
  defensible answers.

## `label.json`

```json
{
  "schemaVersion": 2,
  "checks": [
    {
      "id": "verdict",
      "kind": "value",
      "array": "verdicts",
      "where": [{ "path": "id", "oneOf": ["ev-tca-cancellable-always-cancels-in-flight"] }],
      "field": "status",
      "expected": "refuted"
    }
  ]
}
```

A label holds checks on what the agent returns, never questions put to the agent. Each check has
a unique `id` and a `kind`:

| `kind` | Keys | Met when |
|---|---|---|
| `present` | `array`, `where` | some element of the top-level `array` meets every condition |
| `absent` | `array`, `where` | no element of `array` meets every condition |
| `value` | `array`, `where`, `field`, `expected` | every element that meets the conditions has `expected` at `field`, and one does |
| `judge` | `text`, `options`, `expected` | a separate judge, reading only the agent's output, picks `expected` at p ≥ 0.7 |

- A condition is `{"path", "oneOf": [...]}` or `{"path", "prefix": "..."}`. `path` and `field`
  are dot-separated keys, such as `location.anchor`. A string array at `path` matches when any
  of its strings does. `where` may be left out to match every element.
- A `judge` check is for a label no JSON field carries: the drafter returns a document. Its
  `text` asks what the output holds and never names the expected option, its options aren't
  `yes`/`no`, and the judge's prompt and schema are built without `expected`.
- `schemaVersion` is `2`. Unknown keys, a missing key or an empty value exit 1 with
  `calibrate-design.invalid-label` naming the file.

## How a case runs

The agent's body (its file after the frontmatter) is the system prompt, and `input.md` is the
whole prompt on stdin. The agent runs on the model its frontmatter names (`sonnet` when it names
none), with `claude -p --output-format json --restricted --tools "" --strict-mcp-config
--no-session-persistence --settings '{"verbose":false}'`. It gets no tools, so a case must carry
everything the agent needs. It answers in its own output contract: one JSON object (a fence
around it is read through), or a design doc for the drafter.

The checks score that reply. An observed check records probability 1. A judged check records the
judge's probability for its most likely option, and passes only when that option is `expected`
and its probability is at least 0.7: an answer that lands on the label by a coin flip is a miss,
not a pass. Every check in every case met: exit 0, and `last-pass.json` is rewritten. Any miss:
exit 1 with one `calibrate-design.label-missed` per check, and `last-pass.json` is left as it
was. When `claude` can't run or returns an error, or a seed can't be read, the run exits 2.

`--model <m>` runs every agent on `<m>` instead, for experiments. The record it writes carries
`modelOverride`, and push never counts it as fresh.

## `last-pass.json`

A `CalibrationRecord`: `schemaVersion` (2), `contentHash`, `hashedFiles`, `modelOverride` (only
on an override run), `passedAt` (ISO 8601) and `cases` (`agent`, `case`, `model`, and `answers`
with `question`, `expected`, `answered` and `probability`). `contentHash` is SHA-256 over the
sorted list of `agents/design-*.md` and `workflows/design-*.js` (direct children only). Each file
contributes `<path>\0<sha256 of its bytes>\n`, so an edit, an added or removed file, or a rename
changes it.

## Freshness at push

`swiftgate check --tier push` compares `contentHash` with the hash of the working tree's prompts,
and each agent's frontmatter `model` with the `model` of its recorded cases. A hash mismatch is
`calibration-freshness.stale`. A case run on another model than its agent ships on, an agent
with no recorded case, or a `modelOverride` is `calibration-freshness.wrong-model`. No record is
`calibration-freshness.no-record`, and an undecodable record or unreadable prompt is
`calibration-freshness.unreadable`. All are major, so push is red until `swiftgate calibrate
design` passes on the shipped models and its record is committed. A repository with no
`agents/design-*.md` skips the check with a `calibration-freshness.summary` note. Editing a seed
doesn't change the hash, so rerun the calibration after changing one.
