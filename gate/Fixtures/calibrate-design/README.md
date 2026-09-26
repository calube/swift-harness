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
--output-format json --restricted --tools "" --strict-mcp-config --no-session-persistence`).
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
