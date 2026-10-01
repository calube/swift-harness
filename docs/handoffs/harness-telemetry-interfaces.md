# Harness telemetry: interfaces note

What later telemetry workers need from merged work. Each wave appends a section. The plan is
[2026-09-30-harness-telemetry-plan.md](../plans/2026-09-30-harness-telemetry-plan.md); the design is
[2026-09-30-harness-telemetry-design.md](../designs/2026-09-30-harness-telemetry-design.md).

## Before wave 1: the judge audit log

Merged as ef5832d. Where it differs from the design, the code wins, and the design follows at the next docs task.
- Envelope `HarnessEvent {schemaVersion, eventID, parentID?, kind, time, runID?, head?, base?, source: {route?, tier?, hook?}, payload}`. A missing `route` means unattributed.
- Kinds map to streams through `HarnessEventKind.stream`, and each stream is 1 file: both `judge.decision` and `judge.call` go to `.harness/events/judge.jsonl`, not 1 file per kind. Each run also keeps a copy at `.harness/runs/<id>/events/judge.jsonl`.
- The writer protocol is `HarnessEventWriting`; `HarnessEventFiles` stores it. A failed write is the nit `judge-events.unwritten` and never changes the verdict.
- Judge reasons and rationales can exceed the design's 512-byte payload guard. The guard must not drop or truncate a judge decision's reason: the judge log is the audit trail, and it stays on under `[telemetry] enabled = false` (user, 2026-09-30).
- Routes: `check-ready`, `judge-tests`, `judge-tests-ready`, `comment-hook`, `calibrate-design`, `judge-ask`, `bench`, `self-test`. A `judge.call`'s `role` is `answer`, `escalation` (parent: the Jev call) or `reason` (parent: the block's decision).
- `swiftgate judge events [--since <runID|ISO>] [--run <id>] [--route r] [--backend b] [--json]` exits 0, 2 for bad input or a newer schema, and 64 for an unparseable flag. The route table is in `plugin/docs/judge-audit.md`.
- `.harness/events/` is git-ignored here and in `plugin/templates/gitignore`.

## Wave 1, merged so far

- `xunit-and-xcresult-carry-durations` (583cee6): `XUnitTestCase.milliseconds: Int?` and `XcresultTestCase.milliseconds: Int?`, each init's last parameter defaulting to `nil`. The value is `Int(exactly: (seconds * 1000).rounded())`; NaN, infinity or an unparseable time gives `nil`. Swift Testing cases under 0.5 ms give `0`.
- `throwaway-session-usage-is-captured` (26441ba): fixtures in `plugin/gate/Tests/Fixtures/Transcripts/`, capture recorded in the fixtures README. Claude Code keeps a main transcript as `<session_id>.jsonl` in its per-project directory, and a subagent's as `<session_id>/subagents/agent-<id>.jsonl`; the fixtures README names the directory. Usage keys: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `cache_creation.ephemeral_{5m,1h}_input_tokens`. A message with 2 content blocks gives 2 lines with the same `message.id` and usage; usage deduplicated by message id equals the envelope's `modelUsage`. The envelopes solve to $4 input, $5 5-minute cache write and $0.20 cache read per million tokens for `claude-opus-5-5`; the output price was not confirmed.
