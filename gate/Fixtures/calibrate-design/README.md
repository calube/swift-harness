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

Each case plants one defect, and the label fixes the answer the agent's own prompt requires. Each
defect has a clean twin: the same case with the defect removed, where the agent must not flag it.
The spec's layer 2 seeds come first; the rest give every other design agent a case.

| Agent | Defect case: expected answer | Clean twin: expected answer |
|---|---|---|
| `design-claim-checker` | `overstated-claim`: a genuine quote under a claim that says "always": `refuted` | `genuine-quote`: the same quote, a claim that says only what it shows: `supported` |
| `design-evidence-auditor` | `decision-contradicts-evidence`: the Decision says queued orders survive termination, citing a claim that they live in memory only: gating, at `decision`, `blocker` | `decision-follows-evidence`: the Decision claims only in-session retry: no gating finding |
| `design-evidence-auditor` | `option-on-probe-refuted-api`: the chosen option cites a claim whose probe failed: gating, at `decision`, `blocker` | as above |
| `design-standards-conformance` | `uikit-in-core-module`: a Core module imports UIKit: gating, rule `A2` | `uikit-in-live-module-only`: UIKit sits behind a client in its `*Live` module: no finding |
| `design-challenger` | `option-on-probe-refuted-api`: the chosen option rests on an API the probe refuted: gating, at `decision` | `option-on-probe-passed-api`: the chosen option's APIs all passed their probes: no finding |
| `design-pre-mortem` | `unbounded-prefetch`: one download per album photo, all at once: gating | `bounded-prefetch`: at most 6 in flight, tested: no finding |
| `design-drafter` | `point-without-supported-claim`: a frame answer no supported claim backs: `[UNVERIFIED]`, repeated in Risks or Open questions | `point-with-supported-claim`: the pack holds a claim that backs it: cite it |
| `design-decomposer` | `flow-test-needs-ready-gate`: a T3 test: gate `ready` | `host-test-needs-fast-gate`: a T1 test: gate `fast` |
| `design-lane-codebase` | `product-intent-question`: the brief asks a product choice: `needsDecision` | `code-fact-question`: the brief asks what code does: a `file` claim |
| `design-lane-apple-docs` | `signature-needs-probe`: a snapshot shows a signature: a `probe` claim | `semantics-from-snapshot`: the snapshot states behaviour: a `snapshot` claim |
| `design-lane-packages` | `pinned-package-not-checked-out`: the pinned package has no checkout: `needsDecision` | `pinned-package-checked-out`: a claim citing the checkout, pinned `<pkg>@<version>` |
| `design-lane-prior-decisions` | `refuted-prior-claim`: a prior claim was refuted: a warning claim citing the earlier design | `supported-prior-file-claim`: carried forward with its original id, status `new` |

Questions name one option to pick, with 2 or 3 options. The judge rejects a reply whose
probabilities for one question don't sum to 1, and models drift from that as the option list grows.

## `label.json`

```json
{
  "schemaVersion": 1,
  "questions": [
    {
      "id": "verdict",
      "text": "Does the quoted evidence support the claim as written?",
      "options": ["supported", "overstated"],
      "expected": "overstated"
    }
  ]
}
```

- `schemaVersion` is `1`. There is at least one question, and question ids are unique.
- `options` holds two or more distinct strings, and `expected` is one of them.
- A label that breaks any of these exits 1 with `calibrate-design.invalid-label` naming the file.

## How a case runs

The agent's body (its file after the frontmatter) is the system prompt. `input.md` goes on stdin
inside the judge prompt, and each question becomes a `--json-schema` property with one
probability per option. The flags and reply parsing are the Foundation judge's (`claude -p
--output-format json --restricted --tools "" --strict-mcp-config --no-session-persistence
--settings '{"verbose":false}'`).
The agent gets no tools, so a case must carry everything the agent needs to answer.

A question is met when the agent's most probable option equals `expected`. Every question in
every case met: exit 0, and `last-pass.json` is rewritten. Any miss: exit 1 with one
`calibrate-design.label-missed` per question, and `last-pass.json` is left as it was. When
`claude` can't run or returns an error, or a seed can't be read, the run exits 2.

## `last-pass.json`

A `CalibrationRecord`: `schemaVersion` (1), `contentHash`, `hashedFiles`, `model`, `passedAt`
(ISO 8601) and `cases` (`agent`, `case`, and `answers` with `question`, `expected`, `answered`
and `probability`). `contentHash` is SHA-256 over the sorted list of `agents/design-*.md` and
`workflows/design-*.js` (direct children only). Each file contributes
`<path>\0<sha256 of its bytes>\n`, so an edit, an added or removed file, or a rename changes it.

## Freshness at push

`swiftgate check --tier push` compares `contentHash` with the hash of the working tree's prompts.
A mismatch is `calibration-freshness.stale`, no record is `calibration-freshness.no-record`, and an
undecodable record or unreadable prompt is `calibration-freshness.unreadable`. All three are major,
so push is red until `swiftgate calibrate design` passes and its record is committed. A repository
with no `agents/design-*.md` skips the check with a `calibration-freshness.summary` note. Editing a
seed doesn't change the hash, so rerun the calibration after changing one.
