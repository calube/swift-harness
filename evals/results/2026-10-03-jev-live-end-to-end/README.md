# Live end-to-end check of the Jev judge

- **Date:** 2026-10-03; the run ids carry 2026-10-04 UTC.
- **Harness commit:** `c9d75998`, with "a configured judge that can't run fails loudly" merged.
- **Served models:** `jev-1.13.0` for every Jev answer that reached TypeSafe, and `claude-sonnet-5-5`
  (configured as `sonnet`) for escalations and block reasons.

## What ran

A scratch Swift package, `PriceKit`, outside every repository, stamped with `swiftgate bootstrap --apply` from
this commit's plugin. [consumer-files.txt](consumer-files.txt) holds its sources, tests and `[judge]` table. The
base commit has the sources and the harness files; the branch under test adds 2 tests:

- `discountRoundsDownToWholeCent()`, the good test: 3 `#expect`s on `discountedPrice`.
- `cartTotalsLineItems()`, the hollow test: it builds a cart and discards `totalCents` with `_ =`, asserting nothing.

`[judge]` sets `backend = "jev"` and `send_to = "api.typesafe.ai"`. This commit has no threshold defaults yet
(issue #11), so the table sets `advisory_threshold = 0.6` and `block_threshold = 0.9` itself.

Every command ran from the package root as the worktree's `plugin/bin/swiftgate`, with the answer cache cleared
before each judge run. The key came from the login shell into the environment and appears in no file here;
before committing, a grep for its prefix found nothing. The fake key in scenario c is `tsk-fake-0000000000000000`.

**The unreachable host.** The Jev endpoint is a constant (`JevPin.endpoint`); nothing in config or the
environment overrides it, and `send_to` must name `api.typesafe.ai`. So scenario b runs swiftgate under
`sandbox-exec` with [nonet.sb](nonet.sb), which denies all outbound network except localhost. `URLSession` ignores
`HTTPS_PROXY`, so the Jev call fails with a transport error. The `claude` child inherits the sandbox but honours
`HTTPS_PROXY`, which points at [proxy.py](proxy.py), a localhost CONNECT proxy outside the sandbox that refuses
`api.typesafe.ai` and tunnels the rest. Its log showed no `api.typesafe.ai` request, so Jev never went through it.
For b2, `PATH` also drops the directories that hold `claude`.

## Results

| Scenario | Command | Expected | Observed | Pass |
|---|---|---|---|---|
| a. Live Jev, both tests | `judge tests --ready --base main` | hollow blocks with a Claude reason; good passes | RED, exit 1; 1 major `judge.fails-if-broken` on `CartTests.swift:4`, Jev p=0.96, reason from `claude-sonnet-5-5`; the good test passes all 4 questions | yes |
| b1. Jev unreachable, Claude answers | `sandbox-exec -f nonet.sb … judge tests --ready` | 1 retry, cascade to Claude, Claude decides | 2 Jev `answer` calls per test, both `transport`; Claude escalation `cause: jevFailed` blocks the hollow test (p=0.97) and passes the good one; minor `judge.not-run`; RED, exit 1 | yes |
| b2. Jev unreachable, no `claude` | the same, `PATH` without `claude` | BLOCKED, `judge.blocked` naming both errors | BLOCKED, exit 2, both errors named; the rule id is `swiftgate.environment`, not `judge.blocked` (finding 1) | partly |
| c1. Bad key | `TYPESAFE_API_KEY=tsk-fake-… judge tests --ready` | 401, no retry, escalates to Claude | 1 Jev call per test, error kind `backend` with TypeSafe's 401; Claude escalation `jevFailed` blocks the hollow test; RED, exit 1 | yes |
| c2. `doctor`, key missing | `env -u TYPESAFE_API_KEY swiftgate doctor` | `doctor.judge-key` major | major `doctor.judge-key`, RED, exit 1 | yes |
| c3. `doctor`, key set | `swiftgate doctor` | no `doctor.judge-key` | GREEN, no `doctor.judge-key` | yes |
| c4. Key missing at ready | `env -u TYPESAFE_API_KEY … judge tests --ready` | escalates to Claude, not a silent `judge.not-run` | Jev `notConfigured`, Claude `jevFailed` blocks the hollow test; RED, exit 1 | yes |
| d. Audit log | `judge events`, `judge events --json` | each decision with backend, served model and escalation cause | counts per question and backend, the 4 blocks with `decidedBy` and reason, errors by kind; served model and cause only in the raw log (finding 2) | partly |

Run ids: a `20261004T025850Z-413cd275`, b1 `20261004T030028Z-26d3fdc7`, b2 `20261004T030051Z-7d39633f`,
c1 `20261004T025913Z-477359c2`, c2 `20261004T025944Z-54ce29b0`, c3 `20261004T030146Z-9e39e61d`,
c4 `20261004T030158Z-4d269042`. Live Jev latency in a: 384 and 386 ms; the whole check cost about 0.04 USD.

## Findings

1. **`judge tests --ready` reports a blocked judge as `swiftgate.environment`, not `judge.blocked`.** The
   domain builds a `judge.blocked` finding, but `TestJudgeCheck` turns any `judge.blocked` into
   `.blocked(reason:)`, and `StaticCheckReport.make` replaces every finding with 1 minor
   `swiftgate.environment` finding. The verdict and exit code are right; the rule id differs from
   `judge-audit.md`, the playbook §5.4 and the standards rule index. The report also drops the minor
   `judge.not-run` note. This check didn't run `check --tier ready`, so that route is unchecked. Repro: scenario b2.
2. **`judge events` names no served model and no escalation cause.** It reports `decidedBy` as
   `backend/configured model` (`claude/sonnet`) and counts escalations without splitting `jevFailed` from
   `uncertain`. Each `judge.decision` in the log carries `escalation.servedModel` and `escalation.cause`
   (see [decisions-and-calls.txt](outputs/decisions-and-calls.txt)), and `judge-audit.md` promises no more,
   so this is a gap against the check's expectation rather than against the docs.
3. **The b2 message embeds the whole `PATH`.** `claude could not start: not found on PATH …` prints every
   directory, so a report carries the machine's home paths; `~` stands for them here.
4. **The retry is immediate.** The 2 Jev calls after a transport error are 4 ms apart. That meets "1 retry"
   but helps little with a transient network blip.

## Files

- `outputs/*.txt`: each command's output and exit code; `decisions-and-calls.txt` extracts every call and
  decision per run from the log.
- `runs/<run id>/`: each run's `report.json` and its copy of the judge log.
- `~` and `<scratch>` stand for the home and scratch paths.
