# Practice-app results: brownfield one-shot (2026-10-04 to 2026-10-05)

Seven practice apps ran as brownfield one-shots. Each run starts from a fresh repo cloned from a shared starter
project plus a `spec.md`, then runs `swiftgate run spec.md` headless, with no input and a 40-minute time box. A run
passes only when it ends inside the box, every row has a real result, the flow rows pass with simulator video, and
the report is whole. Every failed attempt became a generic fix worker per finding, then a full suite run, then a
push, then the next attempt.

The harness froze after the loop, at the tag `harness-freeze-2026-10-05`. The last section of this page lists the open
follow-ups; none has started.

## Passing runs

All 7 apps pass.

| App | Attempts to pass | Wall time | Cost | Rows verified | Flow rows | Video | Input |
|---|---|---|---|---|---|---|---|
| tic-tac-toe | 2 | 30.9 min | $4.36 | 5 + 2 reason-only | 5 of 5 pass | yes | 0 |
| send-money | 7 | 29.5 min | $5.88 | 7 of 10 | 7 of 7 pass | yes | 0 |
| price-tracker | 6 | 32.0 min | $5.45 | 5 of 8 | 5 of 5 pass | yes | 0 |
| pos-checkout | 1 | 25.1 min | $4.53 | 6 of 9 | 6 of 6 pass | yes | 0 |
| chat-app | 3 | 30.7 min | $5.83 | 7 of 10 | 7 of 7 pass | yes | 0 |
| pacman | 1 | 26.9 min | $5.81 | 4 of 12 | 4 of 4 pass | yes | 0 |
| swipe-arcade | 4 | 27.7 min | $6.86 | 6 of 12 | 6 of 6 pass | yes | 0 |

"Rows verified" counts rows with a simulator or test result; the rest are reason-only rows that a unit test or the
final gate covers. No passing run reached its cutoff, needed input, or asked a question.

| Measure | Value |
|---|---|
| Attempts, all apps | 24 |
| Passing runs, mean wall time | 29.0 min (range 25.1 to 32.0) |
| Passing runs, mean cost | $5.53 (range $4.36 to $6.86) |
| Flow rows passing with video | 40 of 40 |

## How the failures moved

Each failed attempt stopped further down the pipeline than the one before, so the loop measured progress by where
a run stopped, not only by pass or fail.

| Attempt | Wall time | What stopped it | Fix |
|---|---|---|---|
| chat-app 1 | 39.8 min | The orchestrator hung 2 × 600 s on shell aliases (`cat` → `bat` on stdin, `cp -i` at a prompt) | Run sessions clear aliases, turn off `noclobber` and close stdin; `check-return` stores returns itself |
| chat-app 2 | 25.7 min | A flow checked a short-lived in-flight state no fake scenario held; the build stopped with 11 min left | Contracts give each in-flight state a `held` scenario; `build no-repair` never stops the build before the cutoff |
| swipe-arcade 1 | 31.2 min | A clock-driven screen had no way to hold still, so its starting state drained before the check read it | `plan import` refuses a clock-driven screen with no held scenario |
| swipe-arcade 2 | 31.1 min | A real app defect was misread as a timing race | The fixer judges a red row from its frames and reproduces it in a unit test before blaming timing |
| swipe-arcade 3 | 33.1 min | qa's own captures (about 1.2 s per check) delayed a check of a 2.8 s state | Recorded qa runs take one snapshot per check and fill images from the video (about 0.4 s per check) |

## Measured speed changes

| Change | Before | After |
|---|---|---|
| Contract slice gate, with the warm-up building slots one at a time | 240 to 248 s | 55 to 58 s |
| Merge prove, with a kept and pre-built prove tree | 85 s | 65 s |
| Final prove, reusing the last merge gate's prove on the same head | 54 to 77 s | 9 s |
| qa capture time per check, recorded runs | 1.1 to 1.3 s | 0.35 to 0.44 s |
| Guard refusals per run (reviewer Bash, raw `swift build`) | 14 + 3 | 0 |

## Harness work in the loop

| Measure | Value |
|---|---|
| Merges to `main`, 2026-10-04 18:00 to the freeze tag | 124 |
| Merges to `main` on 2026-10-05 | 73 (318 non-merge commits) |
| Lines changed on 2026-10-05 | +73,695 / −2,556 across 1,029 files, 1,002 of them under `plugin/`, mostly captured test fixtures |
| `swift test` suite size | 4,534 → 4,689 tests, per `swift test` output |
| Pushes on 2026-10-05 | 16, each after two clean full-suite runs in a row and a leak scan |

The counts are recomputed against the tag `harness-freeze-2026-10-05`, with times in UTC−5. Merges
are `git log harness-freeze-2026-10-05 --first-parent --merges --since=<start>`, with start
`'2026-10-04 18:00 -0500'` or `'2026-10-05 00:00 -0500'`. Non-merge commits are `git log
harness-freeze-2026-10-05 --no-merges --since='2026-10-05 00:00 -0500'`. Lines are `git diff
--shortstat` from `32f3349d`, the last `main` commit of 2026-10-04, to the tag. Pushes are the
2026-10-05 `update by push` entries in the orchestrator clone's `origin/main` reflog.

Fixes that showed no reliable measured win stayed unmerged: running warm-up builds at a lower priority, and running
only the changed UI tests in prove.

## Lessons

- Run trials solo. Two at once loaded the machine to 300 to 900 and starved the shared simulator slots.
- Pin each trial to a detached worktree of `main`; `main` moves while it runs.
- Expect about 1 break between merges per batch (an unregistered rule id, a stale snapshot, a doc check), even
  when every branch was green alone. Run the full suite after each batch.
- Load-dependent test flakes were all the same class: a test waiting on wall-clock time. Wait on a signal or a clock the
  test moves.
- A rule written from a single failure can over-correct the next. The rule that told the fixer to treat a moving
  state as a timing race hid a real app defect an attempt later; requiring evidence first fixed both cases.

## Open follow-ups at the freeze

None of these has started. Each is generic harness work; none blocks a passing run.

- A long qa step label drops its `qa.flow` event, because `EventPayloadGuard` caps each payload string at 512 B, so that
  Validation row loses its step timeline.
- `qa lint` should flag a huge OR selector.
- A test-failure message leads with `IssueReporting` boilerplate, and the cut-off message loses the real assertion.
- Halt decisions need a sanctioned `swiftgate plan note`, so the orchestrator never writes plan state by hand.
- The `build no-repair` contract-name parser accepts a prose reason where it should take a contract name.
- `check` has no `--output` flag, so a caller redirects its output by hand.
- An owned-repo fix worktree keeps its own `.harness`, so another checkout doesn't see its qa runs.
- The run viewer page doesn't render the deferred list that `view.json` carries.
- Two parked branches stay unmerged. `warmup-background-priority-unmerged` runs warm-up builds at a lowered
  priority and showed no measurable win; `taskpolicy -c utility` is the untried alternative.
  `prove-only-changed-ui-tests-unmerged` runs only an xcode area's changed UI tests in prove and showed no reliable
  measured win.
- A simulator clone costs about 50 s to boot for prove.
- A manual run of the swipe-arcade app showed the score and lives display overlapping the status bar and safe area,
  and a score other than 0 at an unheld launch. No flow checks safe-area layout or the unheld launch state.
