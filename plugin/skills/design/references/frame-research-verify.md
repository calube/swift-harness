# Frame, research, verify, draft

The long form of the design skill's first 4 phases. The names `<slug>`, `<plan>`, `<doc>`, `<ev>`,
`<run>` and `<design-run>` mean what the skill's table says. `SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`.

Write JSONL files as compact JSON, 1 object per line, and append rather than rewrite unless a step
says to rewrite. Time stamps are UTC ISO-8601 to the second with a `Z` and no fraction, as
`date -u +%Y-%m-%dT%H:%M:%SZ` prints them.

Contents:

- [Frame](#frame): ask, scope, claim, branch and record
- [Research](#research): lanes, packs, the workflow, halt and resume, writing results
- [Verify](#verify): mechanical check, probe, claim checker, final statuses
- [Draft](#draft): pack, drafter, lint and revise
- [Phase log](#phase-log): the `phases.jsonl` line

## Frame

### Ask

Gather the options before you ask:

- areas: the directories under `docs/` that hold a `designs/` folder, plus a new area the goal
  suggests;
- modules: the `Modules by package` lines of the SessionStart context, each with its kind;
- dependencies: the pins in `Package.resolved`.

Ask with `AskUserQuestion`, at most 4 questions per prompt, recommended option first:

1. Area: the existing area the goal fits, then the others, then a new one.
2. Touched modules (`multiSelect`): the modules the change edits.
3. New modules: each proposal as `<Name> (<kind>)`, and `None`. Kinds are `feature`, `engine`,
   `render`, `library`, `client` and `test-support`.
4. New dependencies: `None` first unless the goal needs a package the repo lacks.

Ask a 5th question about constraints (deadline, platform floor, a module that mustn't change) in a
2nd prompt when the request leaves them open. When the goal itself reads 2 ways, ask which one
first. For every question keep the exact question text, the option labels as shown and the answer:
the chosen label, or the user's own words for a free-text reply.

### Headless

A `claude -p` session has no `AskUserQuestion`. Do every step up to the ask, then end the turn
with only the questions of 1 prompt, so at most 4, and the constraints question waits for the next
turn like any 2nd prompt. List them numbered, each with its exact text, then its options as a
lettered list, recommended first with `(Recommended)` and its description, and a last line saying
the answers come back through `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 claude -p --resume <session id>`
(without it, `claude -p` ends a workflow still running after 600 s). Write no file and claim nothing before the
answers arrive. The resuming message holds the answers, a chosen label or the user's own words,
and they're recorded as the Branch and record step says, exactly as `AskUserQuestion` answers
would be. The same shape serves every later ask in the skill.

### Scope

Write `<run>/frame-answers.json`:

```json
{
  "schemaVersion": 1,
  "goal": "Queue orders while offline and send them on reconnect",
  "area": "ordering",
  "constraints": ["no new third-party dependency"],
  "touchedModules": ["OrderFeature"],
  "newModules": [{"name": "OrderQueueCore", "kind": "engine"}],
  "newDependencies": []
}
```

`design-scope` reads the last 3 keys and ignores the rest. The research and drafter packs carry the
whole file.

```bash
"$SG" design-scope --frame-answers <run>/frame-answers.json --json
```

Exit 2 names the bad entry, such as a touched module the graph lacks or a new module that exists.
Ask that question again with corrected options, then rerun. Exit 0 returns `tier` and `reasons`.

Ask the user to confirm the tier. Put the recommended tier first with its reasons in the option's
description. Offer `quick` only when `design-scope` recommended it: a new dependency or module kind
is never quick. Always offer `deep`.

### Claim

Read the session id from the `Session id: <id>` line of the SessionStart context, then:

```bash
"$SG" plan claim <plan> --session <id> --design <doc> --tier <tier> --json
```

- `claimed`: a new plan. Continue.
- `already-held`: this session holds it from an earlier run. Continue, and keep the files that
  exist.
- `held-by-other` (exit 1): stop. Tell the user which session holds it. Taking over an abandoned
  lock is the user's call: `"$SG" plan release <plan> --force`.
- exit 2: report the message and stop.

If `<doc>` exists and this plan didn't write it, the user wants an amend, which this part of the
skill doesn't cover. Stop and say so.

### Branch and record

Switch to `design/<slug>` (`git switch -c design/<slug>`, or `git switch design/<slug>` when it
exists) in this session's own checkout. Ask first if tracked files have uncommitted changes. Never
write into a sibling worktree's copy of `<doc>`.

Append 1 line per frame answer to `<ev>/answers.jsonl`:

```json
{"runId":"design-20260925T180000Z","question":"Which area does this design belong to?","options":["ordering","payments","A new area: sync"],"answer":"ordering","at":"2026-09-25T18:00:12Z"}
```

`runId` is `<design-run>` for every frame answer. Then append 1 `answer` claim per record to
`<ev>/claims.jsonl`:

```json
{"id":"ev-user-places-design-in-ordering","lane":"prior-decisions","text":"The user placed this design in the ordering area.","citation":{"kind":"answer","loc":"answers.jsonl#design-20260925T180000Z/1","quote":"Which area does this design belong to?"},"status":"new"}
```

- `loc` is `answers.jsonl#<runId>/<n>`, where `<n>` counts the lines with that `runId` from 1, in
  file order.
- `quote` is the question text or a part of it; `evidence check` looks for it in that record's
  question. An `answer` citation has no `pin`.
- The id is `ev-` plus at least 3 words and must not repeat an id in the file.
- Frame answers use the lane `prior-decisions`. An answer to a research lane's question uses that
  lane.

Record the plan in the shared index:

```bash
"$SG" index set <plan> designing "framed at <tier>; next: research"
```

Take a `docs-lint` baseline so the draft step can tell its own findings from older ones:

```bash
"$SG" docs-lint --json > <run>/docs-lint-baseline.json
```

## Research

### Lanes

| Tier | Lanes |
|---|---|
| `quick` | `codebase` |
| `standard`, `deep` | `codebase`, `apple-docs`, `packages`, `prior-decisions` |

### Inputs per lane

- Brief, `<run>/briefs/<lane>.md`: the goal, the constraints and the questions this lane must
  answer. At `deep`, ask each lane for a probe snippet per option, not only for the chosen path.
  Every API or type the request names goes, as the request names it, into the `packages` brief
  (the `codebase` brief at `quick`) as a question that needs a probe snippet using it.
- Module graph, `<run>/module-graph.txt`: the SessionStart `Modules by package` lines, then 1
  `<Target> -> <Dependency>` line per target dependency, from
  `swift package --package-path <package> describe --type json` for each package that holds a
  touched module. The pack keeps the lines that name a touched module.
- Pin: `codebase` takes `git rev-parse HEAD`; `packages` and `prior-decisions` take
  `<identity>@<version>` from `Package.resolved` for the dependency the design leans on most;
  `apple-docs` takes `iphonesimulator<version>` from `xcrun --sdk iphonesimulator --show-sdk-version`.

```bash
"$SG" context-pack --role research-lane --key <lane> --frame-answers <run>/frame-answers.json \
  --area <area> --module-graph <run>/module-graph.txt --brief <run>/briefs/<lane>.md \
  --pin <pin> --claims <ev>/claims.jsonl
```

It writes `.harness/context-pack/research-lane-<lane>.md`. Exit 1 or 2 names the missing input:
fix it and rerun. Never hand a lane a pack you wrote yourself.

### Run

Tell the user how many lanes start. Then:

```
Workflow({
  scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/design-research.js",
  args: {
    tier: "<tier>",
    mode: "research",
    lanes: [{ name: "codebase", packPath: "<absolute path of the lane's pack>" }],
    answers: []
  }
})
```

Keep the `runId` from the tool result. The script returns `status`, an entry per lane, the merged
`needsDecision` list and `unusedAnswers`.

- `needs-decision`: ask, record, relaunch (below).
- `incomplete`: a lane came back `not-researched` with a reason. Tell the user, then ask whether to
  rerun those lanes (recommended) or go on with them marked `NOT RESEARCHED`. A rerun is a fresh
  launch with only those lanes and no `resumeFromRunId`. A design with a missing lane can't reach
  `ready` in review.
- `complete`: write the results.

### Halt, ask, resume

1. Merge the asks: the same question from 2 lanes is 1 question. Keep each question's text
   byte for byte, since the script matches answers by it.
2. Ask with `AskUserQuestion`, at most 4 per prompt, the lane's `recommendation` first. Its
   `evidence` claim ids go in the description.
3. Append each answer to `answers.jsonl` with `runId` = the run that returned the ask, and add its
   `answer` claim with that lane.
4. Relaunch with the same `scriptPath` and the same args, `answers` holding every research answer
   so far as `{question, answer}`, plus `resumeFromRunId: "<that runId>"`. Answered lanes rerun
   from their cached first call; the others replay unchanged.
5. Repeat until the status isn't `needs-decision`. A non-empty `unusedAnswers` means a question
   text changed. Tell the user rather than dropping it.

If this session has no Workflow tool, launch `swift-harness:design-lane-<lane>` with the Agent tool
instead, at most 3 at once. Give each the tier, the absolute pack path and the scope sentence the
script's prompt uses, and ask for the JSON object its agent file defines. Answer a lane's question
with `SendMessage` to that agent; those answers use `<design-run>` as their `runId`.

### Write the results

For each researched lane:

- Append each claim to `<ev>/claims.jsonl` as returned, status `new`. When its id already exists
  with other content, keep the recorded claim and list the clash for the user.
- Write each probe's `swift` text to `<ev>/probes/<claimId>.snippet.swift`, byte for byte.

## Verify

Pass the same `--package-resolved <path>` to every `evidence check` when the pins live outside the
repository root, such as `<App>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

### 1. Mechanical check

```bash
"$SG" evidence check --design <doc> --json > <run>/evidence-check-quotes.json
```

Exit 0 and 1 both return an array of `{id, status}`, with `loc` when a quote moved. Expect exit 1
here: a probe claim has no verdict yet. Exit 2 prints `{message, verdict: "BLOCKED"}`:
report it and stop.

Rewrite `<ev>/claims.jsonl`: for each entry set the claim's `status`, and its `citation.loc` when
`loc` is present. Change nothing else, and keep the line order.

### 2. Probe

Skip this step when `<ev>/probes/` holds no `*.snippet.swift`.

```bash
"$SG" probe --design <doc> --package <package dir> --target <target> --json > <run>/probe.json
```

`--package` and `--target` name the package and target whose dependencies the probes may import:
the touched module's, or for a new module, the target it will sit beside. Exit 0 and 1 are
verdicts; a failed probe refutes its claim. Exit 2 means nothing got judged, often an unpinned
dependency: report it and ask whether to go on with the probe claims unverified.

### 3. Claim checker

Collect the ids whose status is now `quote-ok`, `answer` claims included. Skip this step when there
are none.

```bash
"$SG" context-pack --role claim-checker --design <doc> --claims <ev>/claims.jsonl \
  --claim-id <id> --claim-id <id>
```

When the printed token estimate passes 15,000, split the ids by lane and pass `--key <lane>`, 1
pack each. Launch `swift-harness:design-claim-checker` with the Agent tool per pack, all in 1
message. The prompt names the absolute pack path. Save each reply to
`<run>/claim-checker[-<lane>].json`.

The reply is `{verdicts: [{id, status, reason}], skipped: [{id, reason}]}`. If it isn't, ask the
same agent once with `SendMessage` for that object alone. If the 2nd reply fails too, those claims
stay `quote-ok` and the drafter won't cite them. Tell the user.

### 4. Final statuses

```bash
"$SG" evidence check --design <doc> --json > <run>/evidence-check-final.json
```

Rewrite `<ev>/claims.jsonl` once more. For each claim:

- the checker's verdict (`supported` or `refuted`), when `evidence check` reports `quote-ok` and
  the checker judged that id;
- otherwise the status `evidence check` reports, which is final for probe claims;
- the new `loc` when the output carries one.

A claim missing from both keeps its line as it was. Report the counts by status.

### When verification leaves no path

If every option for a decision rests on refuted or `quote-fail` claims, halt. Ask the user whether
to research again (a fresh launch of the lane with a sharper brief), take an option as a stated risk,
or stop. When `evidence check` marks claims `stale`, rerun the workflow with `mode: "reresearch"`,
`claimIds` set to those ids and 1 lane alone.

## Draft

### Pack

`context-pack` reads repo-relative paths only, so copy the plugin's files into `<run>` first:

- `${CLAUDE_PLUGIN_ROOT}/templates/design-doc.md` to `<run>/design-doc-template.md`;
- `${CLAUDE_PLUGIN_ROOT}/docs/standards.md` and `testing-playbook.md` to `<run>/`, unless the
  repository has its own `docs/standards.md` and `docs/testing-playbook.md`.

```bash
"$SG" context-pack --role drafter --template <run>/design-doc-template.md \
  --frame-answers <run>/frame-answers.json --claims <ev>/claims.jsonl \
  --probe-verdicts <run>/probe.json --standards <standards> --playbook <playbook> \
  --module-kind <kind> --module-kind <kind>
```

Pass 1 `--module-kind` per kind among the touched and new modules. Leave out `--probe-verdicts`
when no probe ran.

### Drafter

Launch `swift-harness:design-drafter` with the Agent tool. The prompt gives the absolute pack path,
`<doc>`, the area, the tier, today's date and the absolute path of
`${CLAUDE_PLUGIN_ROOT}/skills/prose/SKILL.md`. The reply is the whole doc. Write it to `<doc>` as
returned.

### Lint

```bash
"$SG" design-lint <doc> --json
"$SG" docs-lint --json
```

`design-lint` must exit 0. For `docs-lint`, set aside the findings the baseline already had. The
new doc then shows 2 expected rule ids, which publish resolves:

- `docs-lint.unreachable-doc` on `<doc>`: no router row links it yet;
- `docs-lint.requirement-uncited` on `<doc>`: nothing outside the doc cites its requirements yet.

Any other new finding fails the draft.

On a failure, send the findings to the same drafter with `SendMessage`: the `design-lint` findings
and the failing `docs-lint` findings, with a request for the whole doc again. Write the reply and
lint again. After 2 such rounds, halt and ask the user: another round (recommended), or stop with
the findings listed.

When the draft passes:

```bash
"$SG" index set <plan> designing "draft passes design-lint; next: review"
```

## Phase log

Append 1 line to `<run>/phases.jsonl` per agent run and per `swiftgate` step:

```json
{"schemaVersion":1,"runId":"design-20260925T180000Z","phase":"research","agentRole":"research-lane","lane":"codebase","tokens":48213,"costUSD":null,"wallMilliseconds":212000}
```

- `runId`: `<design-run>`.
- `phase`: `frame`, `research`, `verify` or `draft` here.
- `agentRole`: `research-lane`, `claim-checker` or `drafter`, or `null` for a `swiftgate` step.
- `lane`: set only with `research-lane`. Log 1 line per lane when the Workflow result reports lanes
  apart, else 1 line with `lane: null`.
- `tokens` and `wallMilliseconds`: from the tool result's usage figures. A `swiftgate` step logs
  `tokens: 0` and its run time.
- `costUSD`: the reported cost, or `null` when the tool reports none. Never `0` as a stand-in.
