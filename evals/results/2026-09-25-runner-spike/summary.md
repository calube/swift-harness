# Runner spike, 2026-09-25

Tests whether `claude plugin eval` can run the suites, using 1 routing case and 1 `tdd` case.
**Result: use it for routing and for cases that don't run Swift. The `tdd`, `test-gate` and
`validate` cases need the thin runner around `claude -p`**, because the Bash sandbox blocks the
Xcode toolchain.

## Pins

| Pin | Value |
|---|---|
| Agent model | `claude-opus-5-5` (session default, not pinned by flag) |
| Judge model | `haiku` (runner default) |
| `claude --version` | 2.1.282 |
| Harness commit | `0c53f13` plus the eval changes on `evals-foundation` |
| Xcode | 26.2, Swift 6.2.3 |

## Answers

| Question | Answer |
|---|---|
| Can the agent run `swift build`, `swift test` and `bin/swiftgate` in the Bash sandbox? | **No.** `/usr/bin/git` and `swift` are `xcrun` shims, and `xcrun` can't write its cache to the per-user temp dir under `/var/folders`, which the sandbox denies. `swiftgate` starts, but every git call fails, so each tier is BLOCKED, and its run report can't be written. The mise `python3` can't load its dylib from the real `HOME` either. Nothing a case can set lifts this: case `env` keys must start with `EVAL_`, and `--allow-tools` grants tools and domains, not paths |
| Can a scaffold copy `examples/SampleApp` into the workspace? | **Yes,** with 2 conditions. `scaffold_script` must name a file inside the case directory (`..` is refused), so each case links to the shared `evals/cases/_scaffold/sampleapp.sh`. The script gets a scratch `HOME` and no `PLUGIN_ROOT` or `CASE_DIR`, so it walks up to `.claude-plugin/plugin.json`. It runs as the user, outside the sandbox |
| Does the `trace` target show `Skill` and `Agent` calls to a `regex` grader? | **Yes.** Each call is a JSONL line such as `"name":"Skill","input":{"skill":"swift-harness:tdd","args":…}`. `Agent` calls appear the same way. Stop-hook feedback appears as a user message starting `Stop hook feedback:`. SessionStart output appears as `hook_response`. PreToolUse and PostToolUse decisions don't appear |

## Other findings

1. **Every run had its hooks off until the scaffold fixed it.** The scratch `HOME` has no
   `swiftgate` binary, so the SessionStart hook started a cold gate build, which the end of the run
   killed. The hook told the model "swiftgate enforcement is warming up". The scaffold now copies the
   binary and its stamp file from the user's cache into the scratch `HOME`. The next run showed
   no warm-up context.
2. **Hooks run outside the sandbox.** In the `tdd` run the Stop hook built TCA, ran T1 (4 passed,
   1 failed, 45 s) and returned RED to the model. The agent's own `swiftgate` calls in the same run
   were all BLOCKED. Under `claude plugin eval`, the harness's hooks and the agent's own commands
   see 2 different environments, so a `tdd` score there measures the sandbox, not the skill.
3. **The runner ignores `case.yaml` execution fields when `prompt.md` exists.** `max_turns: 40` and
   `timeout_seconds: 1500` in `case.yaml` ran as the defaults, 10 and 300. They now live in the
   `prompt.md` frontmatter, and a rerun confirmed `maxTurns` 4 on the routing case.
4. **The plugin-off arm can't discriminate for routing.** Without the plugin, no `swift-harness:*`
   skill exists, so the routing case scores 0 there by construction. The runner scores
   `tool_used: Skill` in both arms anyway when it is a case's only grader type. Routing runs
   should use `--ablation none` and get their negative side from near-miss cases.
5. **The harness behaved well under a broken environment.** Faced with the sandbox, `swiftgate`
   reported BLOCKED with a `swiftgate.environment` finding, not GREEN. The model stopped before
   editing the reducer and named the block. That makes it a `failure-modes` data point.

## Runs

| Run | Case | Arms | Result | Cost (USD) | Wall |
|---|---|---|---|---|---|
| 1 | routing | with, without | refused: scaffold path escapes the case dir | 0.00 | 0 s |
| 2 | routing | with, without | with 1/1, without 0/1 (by construction); hooks off | 0.44 | 86 s |
| 3 | routing | with | 1/1; hooks still off (stamp hash mismatch) | 0.42 | 122 s |
| 4 | routing | with | 1/1; hooks live | 0.54 | 109 s |
| 5 | `tdd` | with | score 0.67, judge FAIL; hit the ignored 10-turn cap | 0.31 + 0.05 judge | 108 s |
| 6 | routing | with | 1/1; confirmed `max_turns` from `prompt.md` | 0.19 | 38 s |

Total about 1.95 USD. Transcripts were in the runner's kept `/private/tmp/e-*` directories. The operator deleted
them after the spike.

## Grader checks

| Grader | Known-good | Known-bad | Verdict |
|---|---|---|---|
| `routing/tdd` `loads-tdd` (`tool_used`) | with-arm run: pass | without-arm run: fail; a `test-gate` call whose args mention tdd: fail | separates |
| `routing/tdd` `trace-shows-skill` (`regex`) | with-arm trace: pass | the same trace with the skill renamed: fail | separates |
| `skills/tdd` `swiftgate-test-ran` | not tested | run 5, every agent `swiftgate` call BLOCKED: **pass** | **broken**: it matched the command text. Replaced by `swiftgate-red-seen`, which fails run 5 and passes a synthetic RED report. It still needs a real known-good run |
| `skills/tdd` `test-before-reducer` (`tool_order`) | run 5: pass (test edited at step 4, reducer at step 8) | none yet | unproven on the bad side |
| `skills/tdd` `red-then-green` (`llm`) | none yet | run 5: FAIL 3/3, for the right reason (no GREEN after the fix) | unproven on the good side |

## Harness defects found

| Defect | Evidence | Layer |
|---|---|---|
| `bin/swiftgate`'s cache key depends on the locale: `sort -z` orders the gate's source paths differently under `en_US.UTF-8` and `C`, so the same sources hash to `d70e99948b31ac83` and `655c3346e58e6cc0`. A session whose locale differs from the last build's starts a cold gate build, and the hooks stay off until it finishes | the 2 hashes computed over the same `gate/` tree; the run 3 hook computed `d70e…` while the scaffold computed `655c…` | gate (shim) |
