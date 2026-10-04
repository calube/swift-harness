# Load flakes: diagnosis

Four load-sensitive problems slow merges. This note records what was measured, the cause of each,
and the fix with the test that proves it. The measurements were taken on 2026-10-04 on a 16-core
machine shared with other workers' gates. `uptime` was recorded with every sample, and the load
averages are given with each one.

Every number below comes from a temporary probe. The probe was never committed. It stamped each
`LiveProcessRunner` run at these points: thread start, pipes made, stdin file made (split into
`mkstemp`, `unlink` and write), spawn lock acquired, `posix_spawn` returned, pipes closed, child
reaped (`wait4`, with the child's rusage), loop done, and the awaiting task resumed. A scratch
test ran 200 `/bin/cat` runs with stdin `echo`, as `runsLeaveNoDescriptorsOpen` does, and wrote
one row per run. The probe tagged each trace with a task-local, because other tests' runs share
the runner. An earlier probe version read the last trace in a process-wide list, and other tests'
runs contaminated it; those numbers are discarded.

## 1. `LiveProcessRunnerTests.runsLeaveNoDescriptorsOpen`

### Raw numbers: 200 runs, milliseconds per run

| condition (load at start) | total | wall p50 / p95 / max | resume p50 / p95 / max | stdin p50 / p95 | reap after spawn p50 / p95 | child CPU / wall |
|---|---|---|---|---|---|---|
| (a) alone, `swift test --filter` (33.8) | 1.83 s | 1.8 / 32.5 / 34.7 | 0.01 / 0.03 / 0.04 | 0.52 / 0.81 | 1.1 / 31.4 | 11.8% |
| (a) alone (32.5) | 0.31 s | 1.4 / 1.7 / 29.8 | 0.01 / 0.01 / 0.02 | 0.38 / 0.65 | 0.9 / 1.0 | 53.8% |
| (a) alone (32.5) | 3.43 s | 7.0 / 58.6 / 214 | 0.08 / 3.5 / 9.9 | 1.6 / 29.1 | 2.6 / 33.2 | 10.1% |
| (b) 16 × `yes` (33.1) | 1.22 s | 3.5 / 30.0 / 33.9 | 0.06 / 1.4 / 12.8 | 0.29 / 0.45 | 2.1 / 27.2 | 27.3% |
| (b) 16 × `yes` (35.8) | 2.58 s | 9.5 / 34.4 / 55.3 | 0.91 / 6.2 / 26.9 | 0.33 / 4.3 | 4.0 / 23.2 | 11.8% |
| (c) full parallel `swift test` (42.0) | 44.7 s | 78 / 477 / 17 718 | 0.05 / 394 / 17 552 | 54.5 / 112 | 1.7 / 30.3 | 0.7% |
| (c) full parallel `swift test` (39.7) | 53.8 s | 119 / 823 / 10 776 | 0.03 / 685 / 10 588 | 97.4 / 186 | 1.7 / 26.8 | 0.6% |
| (c) full parallel `swift test` (36.3) | 41.6 s | 68 / 413 / 14 725 | 0.04 / 373 / 14 715 | 48.4 / 104 | 1.9 / 25.5 | 0.8% |
| (c) full parallel `swift test` (48.1) | 71.0 s | 109 / 1 125 / 24 465 | 0.01 / 843 / 24 354 | 97.8 / 181 | 1.2 / 12.3 | 0.3% |

Under the full suite, `mkstemp` is most of the stdin phase: p50 40-89 ms, p95 93-171 ms. `unlink`
takes p50 8 ms, and the write takes 0.05 ms. The other phases stay small in every condition:
thread start p50 0.03-0.08 ms, `posix_spawn` p50 0.1-2 ms, and the spawn lock wait p95 under 3.1 ms.
In one run the spawn lock wait reached 541 ms. The child's own CPU time is 1.1-1.5 ms per run
everywhere. In (c) the first 20 runs take 30.6-50.7 s, and each later block of 20 takes 1.2-4.3 s.
The real test, run in the same suites, took 51.2 s, 46.9 s and 66.8 s against its 60 s budget.

### H1: the runner's own per-run cost. Partly holds; a minor share.

- Thread creation, pipes, `posix_spawn` and the drain cost under 2 ms together in every
  condition.
- The poll cadence is a real cost. When both pipes close before the child can be reaped, the loop
  calls `usleep(20 ms)` and wakes 25-31 ms later. This happened in 1-55 of 200 runs alone and in
  10-27 of 200 under the suite. It is all of the 20-35 ms p95 tail in (a) and (b). Its share of the
  per-run mean is up to 91% in (a), when nothing else is slow, and 1-3% in (c).
- The stdin temp file is cheap alone, at 0.3-1.6 ms p50. In (c) it costs 48-98 ms p50 and is
  26-37% of the probe's total time, almost all of it in `mkstemp` on the shared `$TMPDIR`. That
  directory held 107 344 SwiftPM `*.lock` files and 165 leftover `swiftgate-stdin.*` files while
  the parallel tests created and removed directories in it. The cost comes from contention on the
  directory, not from the runner's own work.

### H2: scheduling delay versus work. Holds; the dominant cause.

- The child's CPU time is 0.3-0.8% of the run's wall time in (c), and 10-54% in (a).
- In (c), `resume` takes 60-70% of the probe's total time. That is the time from the runner
  thread handing its result to the continuation to the test task running again.
- `sample` of the test process during the probe (5 s, 2 764 samples) found all 16 cooperative pool
  threads busy in every sample with synchronous test bodies. `JudgeBenchmarkReportTests` held 7
  threads with CPU work. `SprintStoreTests.fullVolumeRemovesStagingFile` and
  `PlanLockTests.fullVolumeFailsStagingWrite` sat in `mach_msg` for the whole window, inside
  `Process.waitUntilExit()` on `hdiutil`. `TestRollupStoreTests`, `DiscoverTests` and
  `RuleFixtureTests` held the rest. An earlier sample found 6 threads in
  `EventSegmentStoreTests.concurrentWritersAcrossRotation` (`flock`).
- So the runner's thread finished in milliseconds, but the awaiting task waited up to 24 s for a
  free cooperative thread. This is starvation of the in-process pool, not CPU scheduling. The
  16 × `yes` load moved the total from 0.3-3.4 s to 1.2-2.6 s; the full suite moved it to 42-71 s.
- Estimated shares of per-run time in (c): pool starvation 60-70%, `$TMPDIR` contention 26-37%,
  poll cadence 1-3%, everything else under 1%.

### H3: the test's design. Holds: a budget in a leak test, and a process-wide count.

- With no runs at all, the parallel suite moved this process's descriptor count between 9 and
  1 071 (a sampler every 5 ms for 150-200 s). Within 1 s windows the change ranged from -424 to
  +553, and within 50 s windows from -1 040 to +4.
- Leak injected: in a scratch patch the runner skipped `close(stdin)`, leaking 1 descriptor per
  run, and the patch was then reverted. Alone, all 199 runs after the first showed +1. Under the
  full suite, the per-run deltas ranged from -165 to +172.
- Over sliding windows of N runs, deciding "leak" by the median per-run delta under the full suite
  never separated clean from leaky: at N = 31 there were still 18 false negatives in 507 leaky
  windows. The current check, `after - before < runs / 2`, can't hold: the noise is larger than
  the margin in both directions.
- Alone, every clean per-run delta was exactly 0 (995 of 995) once the first run had opened the
  runner's process-wide signal pipe (+2, once). So a child process that runs nothing else needs 1
  warm-up run, then any number of runs, and a delta of exactly 0.
- The slow descriptor count calls `fcntl` once per slot of `getdtablesize()`. With 245 760 slots,
  each count took 40-290 ms.

### Does the runner slow every gate?

No, not by much. With a per-run log, one full `swift test` of the gate package (361 s, load
48 → 15) recorded 7 499 runner spawns: 6 907 `git`, 201 `cat`, 154 `swift` and 130 `swiftgate`.
The gate's own T0 recorded 23 spawns. Totals summed over all 7 499 runs:

- resume wait: 16 334 s, p50 539 ms (test-pool starvation, as above)
- stdin: 58 s
- spawn lock: 18 s
- thread start: 3.8 s
- `posix_spawn`: 3.7 s
- poll-cadence sleeps: 187 runs (2%) × about 25 ms ≈ 4.7 s

These sums run across parallel tasks, so the wall-clock effect is a small fraction of each. The
runner's own overhead is at most a few seconds of a 6-minute suite.

### Fix

The test becomes a pure leak test in an exit test (`#expect(processExitsWith:)`), so the count
runs in a child process where nothing else opens descriptors. It makes 1 warm-up run and 20
counted runs, and expects a delta of exactly 0. It has no wall-clock budget. Its proof: with the
scratch leak patch (no `close(stdin)`), it fails with a delta of 20.

`.serialized` would not isolate the count, because it orders only its own suite. The runner is
unchanged. A shorter wait for the reap after the pipes close (for example 1, 2, 4 … 20 ms) would
save about 25 ms in the 2-27% of runs that hit the sleep. That is a benchmark-driven follow-up,
outside the push gate. It is not a cause of this flake.

## 2. `RepositoryScriptTests.shim()` / `tests/shim_test.sh`: "rm: Directory not empty"

Evidence:

- Five gate runs on 2026-10-04 failed this way, including `20261004T062546Z-b0ad9410` and
  `20261004T105122Z-63d22fd9`. All of them failed on `rm -rf "$sid_cache"` with
  `sid-cache/stamps: Directory not empty`.
- A standalone reproduction of the step (cold `hook session-start` with
  `CLAUDE_PLUGIN_DATA=$sid_cache`, then the test's `kill_background_build`, then `pgrep`, `ls`
  and `lsof +D` just before the `rm`) went wrong in 11 of 11 iterations at load 104-132:
  - `kill_background_build` returned 0 within 56-99 ms.
  - 2-4 processes of the plugin copy were still alive: the detached `bin/swiftgate --version` and
    the hook's background subshell.
  - `sid-cache/stamps` held the files they were writing: `<key>.<pid>.before` and `<key>.<pid>`.
  - `lsof` showed those `bash` processes, and soon after `swift-package` and `swift-frontend`,
    holding `sid-cache/build-*.log`.

Cause: `kill_background_build` matches `$work/repo/plugin/gate`. The detached build's shim
command line is `bash $work/repo/plugin/bin/swiftgate --version`. Until it reaches `swift build`,
it is still hashing the sources and writing its stamp, so the pattern doesn't match it. `pgrep`
finds nothing, the function reports success, and `rm -rf` races the shim's writes into `stamps/`.
The rm fails when a file lands between its `readdir` and its `rmdir`. The cold-sample loop's
`rm -rf "$cache"` has the same race.

Fix: `kill_background_build` matches the whole plugin copy, `$work/repo/plugin/`, which covers the
shim and the build. After each kill, the test also checks that no `$work/repo/plugin/bin/swiftgate`
process is left. Before the fix, that check fails on the shim that is still hashing. After it,
the check holds. Killing the shim also kills what removes the build lock, so
`wait_for_background_build` stops waiting once no process of the copy is left.

## 3. `HookCommandTests.gitCommitJevFailureIsAdvisory`: the 250 ms limit

`Latency.threadCPUMilliseconds` reads `CLOCK_THREAD_CPUTIME_ID` before and after an `async` body.
The hook body suspends. It can resume on another cooperative thread, or on the same thread after
that thread has run other tests' work. Either way, the difference measures another thread's
cumulative CPU, not the hook's.

| condition | samples | same thread before and after | reading |
|---|---|---|---|
| alone (load 18.7), 3 × 5 | 15 | 2 | same thread 2.5-2.7 ms; across threads -306 to +308 ms |
| 16 × `yes` (17.5), 3 × 5 | 15 | 14 | same thread 2.6-7.2 ms |
| full suite (36.3), all `threadCPUMilliseconds` callers | 501 | 448 | same thread: p50 0.8, p95 3.3, max 4 246 ms; across threads: -2 971 to +4 720 ms |
| full suite, the 6 git-commit hook samples | 6 | 1 | 3 331, 4 720, -2 124, 2 376, 123 (same thread, 1 198 ms wall), -2 003 |

The hook's real cost is about 3 ms. The test takes the fastest of 5 samples, so it passes
whenever 1 reading is low or negative. It fails when all 5 resume on threads with more
accumulated CPU, which happens more often under the full suite. The flaw is shared by every
`threadCPUMilliseconds` caller: `HookHarness.run`, `HookRunnerEventsTests`,
`MarkdownLocalPathHookTests` and `BashWriteGuardTests`.

Fix: `threadCPUMilliseconds` runs the body with a task executor preference for a dedicated thread
that runs nothing else, and reads that thread's CPU clock on the thread itself before and after.
Proof: a test makes the caller's own thread burn 300 ms of CPU for someone else while the body
waits. The old reading charges those 300 ms to the body. The new reading doesn't.

## 4. The shared release build cache

The shim builds every gate's binary with `swift build -c release --scratch-path
~/.cache/swift-harness/build/release`. It keys only the copied binary
(`bin/<source hash>/swiftgate`) and the stamp (`stamps/<hash of the gate path>`) by source.

Measured on an APFS clone of the real scratch directory (643 MB), with two exported source trees
A (`main`) and B (`main~8`, 20 source files apart):

- **Lock.** SwiftPM locks the scratch path. Two builds started 2 s apart at load 6: the second
  printed `Another instance of SwiftPM (PID: …) is already running using '…', waiting until that
  process has finished execution...`. A finished at +153 s and B at +291 s: B waited about 150 s,
  then built for about 138 s.
- **Thrash.** Every switch between trees rebuilt all 5 gate modules. Five alternations
  (B, A, B, A, B) took 115-127 s each at load 50-70, with about 208 s of user CPU each. A repeat of
  the same tree was a no-op in 0.4 s.
- **Unconfirmed correctness risk.** In the first sequence, once, building B right after A
  compiled nothing (0.4 s), and `release.yaml` still listed A's 1 768 source paths. The shim
  would then have cached A's binary under B's hash. A deliberate retry, with B's files given old
  mtimes, did not reproduce it. It needs its own investigation.
- **History.** `~/.cache/swift-harness/bin` holds 97 release builds made on 2026-10-04 by 07:22,
  from 62 worktrees. At about 130 s each, the lock was held for about 3.5 h of those 7.4 h. With
  k gates arriving together, the i-th waits about (i - 1) × 130 s. The case of 8+ minutes at
  06:59 fits 3-4 queued rebuilds under load.
- **Per-worktree scratch.** A cold build in a fresh scratch path, swift-syntax included, took
  270 s wall and 387 s user CPU at load 67, and uses about 650 MB of disk. Cloning the shared
  scratch does not help. Every compile command embeds the scratch path, so a clone rebuilds
  everything, and its cloned `ModuleCache` fails with "PCH was compiled with module cache path …".

Recommendation (not implemented): key the scratch by the gate path the stamp already hashes,
`$cache/build/$key/$config`, and prune scratch directories whose gate path no longer exists.
Saved: the queue wait of about (i - 1) × 130 s per gate in a round. With 3 concurrent gates that
is about 130 s on average and 260 s at worst, and the thrash rebuild for every later gate in the
same worktree whose change misses `SwiftGateDomain`. Cost: about 150 s of extra wall time and
about 180 s of extra CPU for the first gate in each worktree, about 650 MB per live worktree
(6.5 GB for 10), and a pruning step. Pruning makes the change more than a one-liner, so the
orchestrator decides.

## Verification after the fixes

- **Descriptor test.** It passed alone (0.56 s), 3 of 3 times under 16 × `yes` (0.17-0.27 s), and
  in 5 of 5 full parallel suites. With the scratch leak patch, it failed: the child exited with
  failure.
- **Shim test.**
  - With the no-shim-left check and the old pattern, it failed at load 21: the
    `hook session-start` subshell and 3 `bin/swiftgate --version` processes were still running.
  - With the wider pattern it passed alone 3 times (51-136 s, load 16-67). It also passed in 3 full
    suites traced at load 34-50. Their 21 kills were all clean, and each kill after a cold
    `session-start` found only the 2 shim processes, before any `swift build` had started.
  - Two earlier untraced full suites hit the test's 540 s deadline. The traced suites did not
    reproduce it.
  - One gap the wider kill opened is closed: the shim it kills is the one that removes the build
    lock. `wait_for_background_build` now stops waiting once no process of the plugin copy is left,
    instead of waiting on an orphaned lock until the deadline.
- **Hook CPU readings.** In the test, the old `threadCPUMilliseconds` read 350 ms for a body that
  spun 50 ms, while its caller's thread spun 300 ms for someone else. In 2 full suites (502
  readings each), the new readings were p50 1.0-1.3 ms, p95 5.0-6.1 ms and max 50 ms. Before the
  fix they ranged from -2 971 to +4 720 ms.

## Issue #8's node walk tests

They share no cause with these flakes. The walks run the debug `gate/.build/debug/swiftgate`, not
the shim, so the release cache lock doesn't reach them. The runner's 60 s timeout starts at spawn
on the runner's own thread, so pool starvation doesn't touch them. Their measured cause stays the
one in issue #8: `dsymutil` in uninterruptible wait during concurrent debug links. Like flake 1,
they put a wall-clock budget on work that machine load stretches.

## Follow-ups found on the way

- `$TMPDIR` holds 107 344 SwiftPM lock files. Most are named after `swiftgate-self-test-plan-lint*`
  temp packages, and each new scratch path leaves one behind. The directory's size and churn make
  `mkstemp` slow for every tool on the machine.
- 165 `swiftgate-stdin.*` files survive in `$TMPDIR`. The runner unlinks each one right after
  `mkstemp`, so these are probably left by mutants or killed processes.
- Tests that block a cooperative thread synchronously: `Process.waitUntilExit()` around
  `hdiutil`, and `flock` waits. They starve every async test in the same process.
