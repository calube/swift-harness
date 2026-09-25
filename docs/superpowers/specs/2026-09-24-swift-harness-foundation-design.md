# swift-harness — Foundation design

<!-- RESUME
Status: DESIGN — sections 1–4 approved in brainstorm 2026-09-24; spec awaiting user review.
Next action: user reviews this spec → writing-plans produces the Foundation implementation plan.
Open items:
  - Point-Free baseline verified 2026-09-24 (§6.2); target TCA 1.26.x, NOT 2.0 beta.
  - Xcode pinned to installed 26.2 (build 17C48; sim runtimes iOS 26.2, 26.4). No Xcode 27 (needs macOS upgrade). Moving to 26.6 later = re-capture xcresult fixtures + bump pin.
  - Confirm current Claude Code Stop-hook input field for re-entry (`stop_hook_active`) against hook docs (§7).
Sub-projects after this one: (2) Design & plan workflows, (3) Simulator QA, (4) Agentic profiling, (5) Build loop & workflows.
-->

## 1. Purpose

A personal, versioned Claude Code plugin that makes Claude a disciplined iOS engineer on SwiftUI
apps: codified standards, a testing playbook, a deterministic gate tool, hooks that enforce it,
and skills that sequence the work. Later sub-projects layer simulator QA, agentic profiling, and
multi-agent review/validation loops on top.

It borrows the transferable patterns of a proven backend harness (every test names its regression,
red/green proof, evidence-not-exit-codes, self-tested checkers, draft-then-ready, RESUME-header
ledgers, one shared verdict vocabulary) and none of its backend-specific machinery.

### Non-goals (Foundation)

- Shipping macOS apps. Apps are iOS-only; macOS appears solely as a host-test platform for Core packages.
- CI. Local-only for now; everything is designed so a CI job can later run the same `swiftgate` command.
- Simulator driving, profiling, review panels — sub-projects 2–5.

## 2. Decomposition

| # | Sub-project | Depends on | Delivers |
|---|---|---|---|
| 1 | **Foundation** (this spec) | — | plugin skeleton, `swiftgate` core, standards, playbook, hooks, bootstrap, core skills |
| 2 | Design & plan workflows | 1 | `/swift-harness:design` (frame — in the main session, questions only via the `AskUserQuestion` tool (multiple-choice, recommended option first, never prose lists), workflow agents that need a user decision message the orchestrator (question, 2–4 options, recommendation, evidence); the orchestrator asks via `AskUserQuestion` (coalescing concurrent asks, ≤4 per prompt), replies, and records the answer as cited evidence. Fallback if mid-run replies to workflow agents prove unsupported: halt and resume — to verify in the sub-project 2 spec → cited-evidence research with symbol probes + claim checking → design doc → 3-agent review incl. self-reflect → published as a Claude Artifact for comment/approval) and `/swift-harness:plan` (per-plan ledger under `.harness/plans/<id>/`; DAG decomposition with per-task write sets, gates, acceptance tests → wave scheduling → `swiftgate plan-lint` → ledger). Ledger canonical in git (`.harness/ledger.json`), orchestrator-only writes; Artifact is the visual view |
| 3 | Simulator QA | 1 | `swiftgate sim`, launch-arg dependency scenarios, QA skill driving `agent-device`, screenshot + accessibility-tree evidence |
| 4 | Agentic profiling | 1, 3 | `swiftgate profile` / `leaks`: xctrace + `leaks` summarized to compact JSON; signpost-scoped measurements; XCTMetric baselines |
| 5 | Build loop & workflows | 1–4 | executes ledger waves across worktrees; review→fix→re-gate loop; full reviewer set; `validate` workflow with sim QA + profile diff |

## 3. Locked decisions

| Decision | Choice |
|---|---|
| Target | SwiftUI iOS apps |
| Baseline | Swift 6 language mode (complete concurrency checking), iOS 18+ |
| App shape | Thin app target + local SPM packages |
| Packaging | Plugin repo `swift-harness` (private GitHub) + `/swift-bootstrap` stamping a thin per-app layer |
| Gate tool | `swiftgate`, a Swift CLI (ArgumentParser); the single enforcement point |
| CI | None yet |
| Architecture default | TCA (~99%); gate is dogmatic, judgment layer recommends exceptions |
| Host tests | Core packages declare `.macOS` only so `swift test` runs on the Mac |
| Xcode | 26.2 as installed (not 27, which needs a macOS upgrade); pinned in config; `DEVELOPER_DIR` selects it per run |

## 4. Architecture overview

### 4.1 Plugin repo layout

```
.claude-plugin/plugin.json
docs/
  standards.md            # rule → violation tell → incident (or source until one exists)
  testing-playbook.md     # tiers, determinism, regression litmus
gate/                     # Swift package: `swiftgate` executable + tests + Fixtures/
bin/swiftgate             # shim: builds gate/ on source-hash change, then execs the binary
hooks/hooks.json          # every hook calls ${CLAUDE_PLUGIN_ROOT}/bin/swiftgate hook <event>
skills/                   # bootstrap, architecture, tdd, test-gate, review, validate, comment-audit
agents/                   # reviewer subagents (one focus each) + finding verifier
workflows/                # multi-agent orchestration scripts: review (Foundation), validate, milestone
templates/                # files /swift-harness:bootstrap stamps into an app repo
```

Component notes (checked against the Claude Code plugin docs, 2026-09-24):

- **Namespacing.** Plugin skills and workflows are invoked as `/swift-harness:<name>`, so names drop
  the `swift-` prefix (`/swift-harness:review`, `/swift-harness:validate`). Elsewhere this spec's
  `/swift-review`-style names refer to these.
- **Workflows vs. skills.** A workflow is a deterministic multi-agent script (fan-out, verify,
  synthesize). A skill is the entry point that sequences gate calls and, where needed, invokes the
  workflow. Foundation ships the `review` workflow; `validate` and `milestone` workflows arrive in
  sub-projects 3–5.
- **Loops are not a component.** Claude Code has no loop component. A loop is a skill or workflow
  designed to be re-run (e.g. under `/loop`), with its state in its plan's `ledger.json` (§4.2), not in the
  conversation.
- **Resolving `swiftgate`.** Hooks use `${CLAUDE_PLUGIN_ROOT}/bin/swiftgate` explicitly rather than
  depending on the plugin `bin/` being on PATH (the docs don't confirm that). Git hooks run outside
  Claude Code, so `bootstrap` installs a stable symlink (`~/.local/bin/swiftgate` → the plugin shim)
  and `lefthook.yml` calls that path; `doctor` reports `BLOCKED` if it's missing or stale.

### 4.2 Per-app layer stamped by `/swift-bootstrap`

- `AGENTS.md` (router to the harness docs; `CLAUDE.md` symlinks to it)
- `.swiftgate.toml` — project profile (§5.4)
- `.swiftlint.yml`, `.swift-format`
- `lefthook.yml` — pre-commit runs `swiftgate comments --staged` (< 1s); pre-push runs `swiftgate check --tier push`
- `.harness/plans/` — one directory per plan (`<date>-<slug>/`: `design.md`, `ledger.json`,
  `evidence/`) plus `index.json` listing plans and status; every ledger and the index carry a RESUME
  summary; orchestrator-only writes (sub-project 2)
- `.harness/runs/` (gitignored) for run artifacts

Ledgers are per plan, per repo: a project can run several plans at once and the plugin itself holds
no project state. A user-level registry `~/.swift-harness/projects.json` records bootstrapped repo
paths only (pointers, not state) so `/swift-harness:status` can list active plans across all Swift
projects; each repo's `index.json` stays canonical. Task worktrees are named
`../<repo>-<plan>-<task>` (siblings of the repo).

Bootstrap is idempotent, shows a diff before writing, and upgrades a previously-stamped repo in place.

### 4.3 The one-CLI rule

Every enforcement point — skills, Claude hooks, git pre-push, future CI — invokes `swiftgate`.
No check logic lives anywhere else. A hook or skill that re-implements a check is a defect.

### 4.4 Multi-session isolation (≈20 concurrent sessions on one Mac)

- **DerivedData:** `swiftgate` passes a per-worktree `-derivedDataPath` (under the worktree's
  `.harness/`), never the shared global path.
- **Simulators:** each simulator-tier run clones the pinned base device (`simctl clone`), uses it,
  and deletes it. A machine-wide file lock caps concurrent simulator runs (default 2; configurable).
  Runs beyond the cap queue.
- **Orphans:** SessionStart and every `swiftgate` start sweep clones whose owning PID is dead.
- **Disk:** `swiftgate gc` prunes stale per-worktree DerivedData and run artifacts.
- **10× check:** the sim cap queues (acceptable, visible in `stats`); disk from per-worktree
  DerivedData breaks first → `gc` + a `doctor` disk-headroom check returning `BLOCKED`.

## 5. `swiftgate`

### 5.1 Commands

```
swiftgate check  --tier fast|push|ready     # orchestrator; composes the commands below
swiftgate lint | arch | impact | testlint   # T0 pieces (testlint = useless-test static checks)
swiftgate coverage                          # diff coverage of Core/Client/Live from T1 alone
swiftgate comments --staged                 # mechanical comment-discipline checks (pre-commit)
swiftgate mutate                            # mutation testing on changed lines (ready tier)
swiftgate test   --tier t1|t2|t3 [--affected-since <ref>]
swiftgate prove                             # red/green proof in a scratch worktree
swiftgate stress --n 10                     # new/changed tests, shuffled order
swiftgate snapshots record                  # only legal snapshot record path; pinned sim enforced
swiftgate doctor                            # Xcode pin, toolchain, sim runtime, disk headroom
swiftgate gc
swiftgate self-test                         # seeded-violation fixtures must FAIL
swiftgate hook <event>                      # hook entrypoints: stdin JSON → decision JSON
swiftgate stats                             # per-tier duration p50/p95, verdict history
```

Tier composition:

| `--tier` | Runs |
|---|---|
| `fast` | T0 + T1 on affected packages |
| `push` | T0 + T1 (all Core) + T2 + impact + `coverage` + per-module T1 presence |
| `ready` | push + T3 + `stress` + `prove` + per-test reach + `mutate` on new/changed code |

### 5.2 Internal layering

- **Domain (pure, no IO):** `Config` (parsed TOML), `ModuleGraph` (from
  `swift package describe --type json`), `TierPlan` (diff + graph → what to run), `EvidenceRule`s
  (parsed results → `Verdict`). Unit-tested with fixtures.
- **Adapters (behind protocols):** `ProcessRunner`, `XcresultReader`, `SwiftPM`, `Git`, `Simctl`,
  `FileLock`, `Clock`. Tested against recorded real outputs checked into `gate/Tests/Fixtures/`.
  `XcresultReader` is the only Xcode-version-sensitive adapter.
- **CLI:** thin ArgumentParser layer mapping flags → domain calls → output.

### 5.3 Verdicts and output

- Verdicts: `GREEN` (code good) · `RED` (code wrong) · `BLOCKED` (environment wrong: Xcode
  mismatch, missing runtime, disk). Claude remediates environment on `BLOCKED`, never code.
- `--json` emits a stable, versioned schema (`schemaVersion`) consumed by hooks and skills.
- Human/Claude-facing output is capped at ~30 lines: verdict, failing test names, assertion
  messages, `file:line`. Full logs + `.xcresult` go to `.harness/runs/<run-id>/`.
- Every run appends a JSONL record (per-tier duration, test counts, verdict) to
  `.harness/runs/history.jsonl`; `stats` reports p50/p95 against tier budgets.

### 5.4 `.swiftgate.toml` (shape)

```toml
schema = 1
xcode = "26.2"                      # doctor → BLOCKED on mismatch
app_scheme = "App"
packages = ["Packages/*"]

[simulator]
device = "iPhone 17"                # pinned for snapshot determinism
os = "26.x"
max_concurrent = 2

[pyramid]
diff_coverage_min = 0.90            # changed Core/Client/Live lines covered by T1 alone
max_flows = 10                      # T3 cap

[[flows]]                           # the closed list of T3 flows
name = "checkout"
reason = "revenue-critical; crosses 3 features"

[mutation]
max_mutants = 30                    # sampled beyond this

[budgets]                           # seconds; stats flags breaches
t0 = 5
t1 = 60
stop_hook = 90

[[modules]]                         # only deviations from default need entries
name = "GameEngine"
kind = "engine"                     # feature (default) | engine | render | library
reason = "60Hz fixed-timestep simulation; per-frame store overhead unjustified"

[clients]                           # vendor SDK modules allowed only inside *Live modules
vendor_modules = ["DatadogRUM", "FirebaseAnalytics"]

[[modules]]
name = "HealthCore"
host_testable = false
reason = "HealthKit types in public API; tests run on simulator"
```

Device/OS values above are placeholders, set from the installed simulator runtimes (iOS 26.2, 26.4).

## 6. Standards

### 6.1 Architecture model

Invariants for every module:

1. Logic lives in a platform-neutral, host-testable **Core** module; the **UI** module is thin.
2. Every source of nondeterminism (clock, RNG, UUID, date, network, persistence) is a dependency.
3. Core tests run under `swift test` on the host in seconds.

Module kinds:

| Kind | Core shape | When |
|---|---|---|
| `feature` (default) | TCA reducer + `TestStore` | Event-driven screens and flows |
| `engine` | Pure `(State, Input) -> State`, seeded RNG dependency, fixed timestep | Real-time loops (>~30Hz), hot pipelines |
| `render` | SpriteKit / `Canvas` / Metal reading engine state; no rules | Rendering layers |
| `library` | Plain Swift | Shared utilities |
| `client` | Interface/Live pair (§6.1.1) | Services: networking, images, analytics, persistence, keychain, auth, flags, push, location |

#### 6.1.1 Client modules (interface / live split)

Every service is **always** two modules, following swift-dependencies' documented
"Separating interface and implementation" pattern (`LivePreviewTest.md`, 1.17.1):

| Module | Contains | May import | Imported by |
|---|---|---|---|
| `FooClient` | `@DependencyClient struct`, domain models, `TestDependencyKey` conformance (unimplemented `testValue`, `previewValue`) | Foundation, Dependencies, other interfaces | anyone |
| `FooClientLive` | `extension FooClient: DependencyKey { static let liveValue }`, real IO, vendor SDKs | vendor SDKs, URLSession, other **interfaces** | **app target only** (composition root) |

`arch` enforces: no feature/engine/render/library module imports a `*Live` module; no `*Live`
module imports a feature; `URLSession.shared` and declared vendor SDK modules appear only in `*Live`
modules. Interfaces must be host-testable; a Live module needing UIKit declares `host_testable = false`.

Reference shapes:

- **Networking** — `HTTPClient` (transport: `URLRequest → (Data, HTTPURLResponse)`) under `APIClient`
  (typed endpoints). `APIClientLive` depends on the `HTTPClient` *interface*, so decoding, auth
  refresh, and retry/backoff are T1-tested against a fake transport with `TestClock`. Only
  `HTTPClientLive` touches URLSession, covered by a thin `URLProtocol`-stub test.
- **Images** — `ImageClient.load(URL, targetSize) → CGImage` (platform-neutral). Live: in-flight
  dedup actor, memory + disk cache with an explicit, tested eviction policy, ImageIO downsampling.
  A thin `RemoteImage` view lives in a shared UI module.
- **Analytics** — `AnalyticsClient.track(Event)` where `Event` is a typed enum (bounded names, no
  strings). Reducers emit events; `TestStore` tests assert them via a recording test double. Live
  fans out to vendor SDKs.

- **Logging** — `LogClient` interface; `LogClientLive` fans out to backends chosen at the composition
  root: OSLog always (Console/Instruments), plus Datadog Logs and/or Sentry breadcrumbs. Constraints:
  - *Structured, privacy-classified payloads.* Wrapping `Logger` with a `String` parameter loses
    OSLog's compile-time privacy redaction and deferred formatting. The interface takes a message plus
    typed attributes each tagged `.public`/`.private`/`.sensitive`; every backend honors the tag
    (OSLog maps to privacy annotations; remote backends drop or hash non-public values).
  - *Cheap when disabled.* Level check before attribute construction (`@autoclosure`); remote
    fan-out is buffered off the caller's thread.
  - *Test value is a recording no-op, not unimplemented* — logging is ubiquitous, so an
    unimplemented default would fail every test. Tests may assert that critical error paths log.
- **Tracing** — `TracingClient` span API (`withSpan(StaticString, attributes) { ... }`). Live maps
  each span to an `OSSignposter` interval (names stay `StaticString`, so Instruments sees them —
  sub-project 4's profiler consumes these) and to Datadog/Sentry spans remotely. Test value records
  spans. Live modules wrap their IO (requests, decodes, cache hits) in spans.

Direct `Logger`, `OSSignposter`, `print`, and vendor logging SDK calls are banned outside
`LogClientLive`/`TracingClientLive`.

**Dogmatic gate, smart judgment.** `swiftgate arch` fails any non-TCA Core not declared in
`.swiftgate.toml` with a `reason`. The `swift-architecture` skill (and later the review panel)
proactively recommends a non-`feature` kind when fit signals appear: per-frame/high-frequency
updates, render loops, high-rate sensor/audio/camera streams, thin SDK wrappers where a reducer
adds ceremony only, or store overhead visible in profiling.

### 6.2 Verified library baseline

Verified 2026-09-24 against GitHub releases, `Package.swift` at each release tag, in-repo DocC, and
pointfree.co posts. No standard may cite an API not verified here; re-verify on each harness release.

| Library | Pin (from) | Notes |
|---|---|---|
| swift-composable-architecture | 1.26.2 | **Target the 1.x shape.** TCA 2.0 (`@Feature`, `Update`) is a subscriber-only beta — do not use. Enable the `ComposableArchitecture2Deprecations` package trait permanently. |
| swift-dependencies | 1.17.1 | `@DependencyClient` endpoints default to fail-and-report; `static let testValue = Self()` = fully unimplemented. `@DependencyEntry` available. App-launch overrides via `prepareDependencies {}` (sub-project 3 scenario injection). Previews: `#Preview(traits: .dependencies {})`. |
| swift-navigation | 2.11.2 | |
| swift-case-paths | 1.10.0 | Prefer `some CasePath` over `AnyCasePath`. |
| swift-snapshot-testing | 1.19.6 | Record modes `.all/.failed/.missing/.never`; **default `.missing` silently records** — see §7.2 rule 4. Use `record:` param / `withSnapshotTesting` / `.snapshots(record:)` trait; globals `isRecording`/`diffTool` deprecated. Package is Swift 5 language mode. |
| swift-clocks | 1.1.1 | `TestClock`, `ImmediateClock`, `.test` constructor. |
| swift-custom-dump | 1.7.3 | `expectNoDifference`; `.customDump` snapshot strategy over soft-deprecated `.dump`. |
| swift-concurrency-extras | 1.4.1 | `withMainSerialExecutor` sets a process-global hook; docs are XCTest-only. Treat as unsafe under Swift Testing parallelism unless the suite is `.serialized` (inferred, not documented). |
| swift-issue-reporting | 2.1.1 | Renamed from `xctest-dynamic-overlay`; depend on 2.1+. |
| swift-sharing | 2.10.1 | |
| swift-perception | — | Not needed at iOS 18+ (native Observation); no `WithPerceptionTracking`. |

Canonical feature shape (TCA 1.26): `@Reducer struct` + `@ObservableState struct State` + `body`
with `Reduce`; actions named for what happened (`saveButtonTapped`, `itemsResponse(...)`).
Navigation: `StackState`/`StackActionOf` + `.forEach`; `@Presents` + `PresentationAction` +
`.ifLet`; enum destinations scoped via `$store.scope(\.destination, action: \.destination).case`.
The `view`/`delegate`/`internal` action grouping is a **house convention**, not an upstream API.

Testing: `TestStore` is `@MainActor`; use `@MainActor` Swift Testing suites; construct the store
inside each test (or `await store.finish()`); exhaustivity via `store.exhaustivity = .on/.off(...)`.

**Banned (lint where feasible):** `ViewStore`, `WithViewStore`, `@BindingState`, `BindingViewState`,
`TaskResult`, `AnyCasePath`, `Store.withState`, Combine effect operators (`.debounce`, `.throttle`,
`.animation`, `.transaction`), `Effect.map`/`.concatenate`, `store.publisher`, legacy
`scope(state:action:)` optional-chained destination form, reentrant `send`, any TCA 2.0 API,
snapshot `isRecording`/`diffTool` globals.

### 6.3 `standards.md` sections

Each rule: **do X · the tell you broke it · incident (or source, until an incident exists)**.

| § | Area | Core rules | Enforcement |
|---|---|---|---|
| 1 | Concurrency | Swift 6 mode; `@unchecked Sendable` / `nonisolated(unsafe)` only with justification; structured over unstructured tasks; no `Task.detached` without reason; honor cancellation | lint (escape hatches) |
| 2 | Architecture | module kinds; TCA conventions (`@Reducer`, `@ObservableState`, `view`/`delegate`/`internal` actions); no logic in views; navigation via state enums + case paths | `arch` + review |
| 3 | Dependencies & clients | `@DependencyClient` with live/test/preview; test value fails loudly by default; no singletons; every service is a `FooClient`/`FooClientLive` pair; typed analytics events | lint + `arch` |
| 4 | Errors | typed domain errors; no `try!`/`fatalError` outside true preconditions; `reportIssue` for programmer errors | lint |
| 5 | Observability | log via `LogClient` (structured, privacy-tagged attributes, per-module category); spans via `TracingClient` on meaningful operations; no direct `Logger`/`OSSignposter`/`print`/vendor SDK outside their Live modules | lint + `arch` |
| 6 | SwiftUI performance | stable identity; no `AnyView`; lazy containers; granular observation | review (+ profiling in sub-project 4) |
| 7 | Accessibility | identifiers + labels on interactive elements | lint (+ QA in sub-project 3) |
| 8 | Checker hygiene | every lint/arch rule has a seeded-violation fixture | `self-test` |

## 7. Testing playbook

### 7.1 Tiers

| Tier | Scope | Runner | Budget | Determinism source |
|---|---|---|---|---|
| T0 static | swift-format, SwiftLint (determinism bans in Core: `Date()`, `UUID()`, `Task.sleep`, `asyncAfter`, `.random`), `arch` (Core ↛ SwiftUI/UIKit, kinds vs config, `@DependencyClient` has `testValue`, `*Live` imported only by the app target, URLSession/vendor SDKs only in `*Live`) | `swiftgate lint`/`arch` | < 5s | no IO |
| T1 host | `TestStore` (exhaustive), dependency clients, engine property + replay tests | `swift test`, affected packages | < 60s | injected deps, `TestClock`/`ImmediateClock`; `withMainSerialExecutor` only in `.serialized` suites |
| T2 simulator | snapshot tests, view/integration tests | `xcodebuild test`, cloned sim | minutes | pinned device+OS, no network, dep overrides |
| T3 flow | thin XCUITest smoke of critical flows | `xcodebuild test`, cloned sim | minutes | launch-arg scenario injection |

### 7.2 Rules (mechanical where possible)

1. **Regression litmus** — every test names the regression it catches and the user-visible symptom.
2. **Red/green** — a new test must fail on an assertion (not compile/import) with the source change
   reverted. `swiftgate prove` reverse-applies the source diff in a scratch worktree and checks.
3. **Evidence, not exit codes** — verdicts come from the xcresult / test output: >0 tests executed,
   no unaccounted skips. `-retry-tests-on-failure` is banned (hides flakes).
4. **No implicit snapshot recording** — the library default (`.missing`) silently records new
   references and passes. `swiftgate` therefore runs every test tier with
   `SNAPSHOT_TESTING_RECORD=never`, so a missing reference fails; any in-code `record:` other than
   `.never`/`nil` is a lint `RED`. Re-recording only via
   `swiftgate snapshots record` on the pinned simulator; reference changes appear in the diff.
5. **Exhaustive `TestStore` by default** — non-exhaustive requires an inline justification.
6. **Flake stress** — new/changed tests run N=10 times, shuffled, at `ready` tier; any failure → `RED`.
7. **Impact** — a changed Core source file requires a test change in the same module, or a filed
   exemption with reason.
8. **Engine determinism** — every `engine` module has a replay test: seed + input log → identical
   final state across runs.

### 7.3 Pyramid enforcement

Raw tier counts are gameable, so the gate enforces **placement** and **reach**:

| Rule | Detection | Tier |
|---|---|---|
| T3 is a closed list: every XCUITest maps to a `[[flows]]` entry; ≤ `max_flows` | test tags/names vs config | T0 |
| A T2 test that renders no view/snapshot and imports only Core/Client modules is misplaced → move to T1 | SwiftSyntax import + usage scan | T0 |
| Every Core, Client, and Live module has ≥1 T1 test | module graph vs discovered tests | push |
| ≥ `diff_coverage_min` of changed Core/Client/Live lines covered by T1 alone | `swift test --enable-code-coverage` → llvm-cov JSON ∩ diff | push |
| Tier runtime budgets, p95 trend | run history | always |

Diff coverage from T1 alone enforces the pyramid indirectly: logic reachable only by simulator
tests is in the wrong module.

### 7.4 Useless-test detection (anti-slop)

Three layers, cheapest first; each check lives at the lowest tier where it is reliable.

**Static — `swiftgate testlint` (T0, SwiftSyntax over test files).** `RED` on:
no real assertion (`#expect`/`#require`/`XCTAssert*`/`store.send|receive` state assertions/
`assertSnapshot`/`expectNoDifference`); tautologies (`#expect(true)`, `x == x`, asserting a value the
test just constructed); existence-only (`!= nil`/`XCTAssertNotNil(sut)` as the sole assertion);
asserting only values the test configured on its own double; `try?` or empty `catch` without
`Issue.record` in a test body; `Task.sleep`/`usleep` in tests; duplicate tests (normalized-AST hash);
`@Test` without a display name; unjustified non-exhaustive `TestStore`.

**Behavioral (push/ready).**
- `prove` — new test fails on an assertion with the source change reverted (§7.2 rule 2).
- `mutate` — mutation testing on **changed** Core/Client/Live lines, re-running affected T1 tests.
  Operators: negate conditional, relational boundary (`<`↔`<=`), return default, remove call,
  remove effect/`send`. **Any surviving mutant → `RED` at `ready`**, unless annotated
  `// swiftgate:equivalent-mutant — <reason>`. Cost ≈ 5–15s per mutant (incremental build + affected
  T1); capped at `max_mutants` with sampling beyond; CPU-bound parallelism; never in the Stop hook.
  Implemented in-house on SwiftSyntax: Muter (muter-mutation-testing/muter) was evaluated — repo
  active but last release 2023, Swift 6 support unverified, and it lacks diff scoping and
  TCA-aware operators. Keep it as a reference implementation only.
- Per-test reach — each new test run alone with coverage; zero production lines covered in the
  module it targets → `RED`.

**Judgment (LLM).** A test-slop rubric in `swift-test-gate` (and a review-panel member in
sub-project 5) for what tools can't see: vacuous or restated regression names,
implementation-detail coupling, over-mocking, wrong abstraction level.

**Judge seam (`swiftgate judge`).** The judgment layer is an adapter behind a `Judge` protocol whose
contract is *typed questions → calibrated probabilities*, not free-form rubric text:

| Question | Type |
|---|---|
| Would this test fail if the behavior it names were broken? | binary → p |
| Which tier does this test belong in (T1/T2/T3)? | choice → p per option |
| How specific is the regression name (vague/partial/specific)? | score → level + p |
| Does it assert implementation details rather than behavior? | binary → p |

- Inputs: test source, covered diff, versioned question set. Output: per-test findings in the
  stable JSON schema (question, answer, probability, one-line rationale where the backend gives one).
- Backends: Claude via structured output first; a Jev adapter later. Jev is TypeSafe AI's decision
  model: Choice / Score / Boolean questions over text or JSON state, answered as probability
  distributions, no prose. It is served through Vercel AI Gateway's native HTTP API (also the AI SDK
  evaluation API and TypeSafe's Python SDK `langchain-typesafe`), so the Swift adapter calls it over
  HTTP directly. Pricing, rate limits, and request schema to be verified when the adapter is built.
- Policy is thresholds, not opinions: p ≥ `block_threshold` may block at `ready`; between the two
  thresholds is advisory; below is ignored. The judge alone never produces `RED` below `ready`.
- Cache by hash(test, diff, question-set version, backend, model) → stable re-runs, zero cost on hit.
  Only new/changed tests are judged.
- Calibration: `gate/Fixtures/judge/` holds labeled useless/good tests; `swiftgate self-test --judge`
  reports precision/recall per question and fails if a question-set or backend change regresses them.
- Remote backends are opt-in per repo (`[judge] backend = "..."`) because test source leaves the machine.

**Escape hatch.** `// swiftgate:allow <rule> — <reason>`; counted in the report; a bare allow
without a reason is itself `RED`.

### 7.5 Comment discipline

Rule: if deleting a comment loses nothing a reader can't recover from the code, delete it. Keep
non-obvious *why*, footgun warnings, suppression justifications, and contract docs (`///`) on
public/shared API. No diff/history narration in source.

- **Mechanical — `swiftgate comments --staged`** (git pre-commit, every commit, < 1s; comments on
  added lines only). High-precision rules **block**:
  - commented-out code (the fragment parses as Swift)
  - diff narration ("previously", "now uses", "switched from", "this PR", "fixed bug where")
  - line-number references
  - `TODO`/`FIXME` without an issue link
  - local paths and private codenames
  - an unjustified suppression: `swiftlint:disable*`, `swiftformat:disable`, `periphery:ignore`,
    `try!`, `as!`, `@unchecked Sendable`, `nonisolated(unsafe)` and `@preconcurrency` each need a
    same-line reason

  Heuristic rules **warn** (fed to the judgment pass, never block):
  - blocks over 3 lines
  - a comment directly above an `if`/`guard`/`return`/`catch` that restates it
  - comments inside test bodies (arrange/act/assert labels; the `@Test` name should carry the meaning)
  - `///` on trivial private declarations
  - AI-prose tells (em-dash clusters, "it's worth noting", "importantly", "not X, it's Y")

  Always kept: `// MARK:`, `#warning`, `@available(..., message:)`, justified suppressions, and `///`
  contracts on `public`/`package` API.
- **Judgment — `/swift-comment-audit` + judge questions** (Claude-authored commits only, via the
  PreToolUse `git commit` hook; advisory, cached by content hash). Runs in an isolated subagent that
  doesn't see the author's reasoning.
  - **Test 1:** would the reader lose a fact the code can't give back? No means CUT.
  - **Test 2:** is a KEEP the right size? If not, TRIM: delete it and rewrite the surviving fact fresh.
  - **Evidence per verdict:** precedent (how often the same construct appears uncommented), owner
    (the fact already lives in a type/doc), ward (a plausible edit that compiles and passes tests but
    is wrong, which the comment prevents), and test (could a test replace the comment? If yes, write
    the test and CUT).
  - Proposes edits for Claude to apply. It never blocks and never runs on human commits.
- Self-test fixtures for each mechanical rule, plus labeled keep/delete examples in the judge
  calibration set.

## 8. Hooks

All hooks are no-ops unless the repo root contains `.swiftgate.toml`.

| Event | Job | Budget |
|---|---|---|
| SessionStart | inject compact context (module map + kinds, Xcode pin vs `xcode-select`, RESUME summaries of active plans from `.harness/plans/index.json`, never whole ledgers); orphan-clone sweep | < 1s |
| PreToolUse (Bash) | block raw `xcodebuild` (route via `swiftgate`), `simctl erase/delete all`, snapshot record flags, global DerivedData deletion | < 50ms |
| PreToolUse (Edit/Write) | block hand edits to snapshot references, `Package.resolved`, `.xcresult` | < 50ms |
| PostToolUse (Edit/Write `*.swift`) | format + lint the single file (incl. determinism bans); report violations. Never builds or tests | < 1s |
| PreToolUse (Bash `git commit`) | Claude-authored commits only: run judge comment questions on staged comments; propose trims (advisory, cached) | ≤ 20s |
| Stop | run `check --tier fast`; **block** if `RED` | ≤ 90s |

Stop-hook safeguards: skip when no `.swift`/`Package.swift` content changed since the last `GREEN`
(content hash); after 3 consecutive blocks, release the turn but stamp output `RED — not done`;
honor the harness re-entry flag; `BLOCKED` does not count as a strike.

## 9. Foundation skills

| Skill | Role |
|---|---|
| `/swift-bootstrap` | stamp or upgrade the per-app layer; idempotent; diff before write |
| `swift-architecture` | judgment layer: design a feature/module, recommend kind via fit signals, scaffold Core/UI package pair |
| `swift-tdd` | test-first with `TestStore` and engine replay/property patterns; regression litmus |
| `/swift-comment-audit` | judgment pass over a diff's comments: keep / trim / delete with proposed edits; Swift-specific, written fresh for this harness |
| `/swift-validate` (thin) | `check --tier ready` → evidence summary in `.harness/runs/<id>/` + PR-body-ready block. Sub-project 3 adds sim QA of changed flows; sub-project 4 adds before/after profile diff and leak check |
| `/swift-review` (thin) | parallel reviewers — concurrency/Sendable, architecture & TCA fit, test quality/slop, API & error design, SwiftUI best practices (when UI is touched) — via the `review` workflow (§9.2), seeded with `arch`/`testlint`/`comments`/`mutate` output; every finding verified against code before reporting; shared verdict contract (below). Sub-project 5 adds observability, accessibility, privacy/security reviewers and the review→fix→re-gate loop (3-round cap, then escalate) |
| `swift-test-gate` | pre-ready sequence: scope → `check --tier push` → test-slop judgment rubric → `check --tier ready` (prove, stress, reach, mutate) |

### 9.1 Review verdict contract

Shared by every reviewer and by sub-project 5's panel so findings merge cleanly:

- Finding fields: `severity` (blocker / major / minor / nit), `file:line`, `failure_scenario`
  (concrete input/state → wrong outcome), `evidence` (tool output, test, or code citation), `fix`.
- Verdicts (literal strings, machine-matched): `merge` · `fix-then-merge` · `refactor-needed`.
- A finding without a concrete failure scenario is dropped at the verify step.

### 9.2 `review` workflow

1. **Gather** (deterministic, no agents): `swiftgate check --tier push --json` + `arch`/`testlint`/
   `comments`/`mutate` outputs + diff → `.harness/runs/<id>/review-input/`. **Gate `RED` → stop**;
   reviewing code that fails its own gate wastes tokens.
2. **Review** (parallel): concurrency/Sendable · architecture & TCA fit · test quality/slop ·
   API & error design · **SwiftUI best practices** (only when the diff touches a module importing
   SwiftUI: view identity, state ownership, observation granularity, `@Bindable`/binding misuse,
   lazy containers, environment/preference misuse, previews with dependency traits). Each returns
   verdict-contract findings.
3. **Verify** (pipelined, one verifier per reviewer, starts as each reviewer finishes): receives
   findings + code, not the reviewer's reasoning; reproduces each failure scenario; drops findings
   without a concrete one.
4. **Synthesize** (deterministic code): dedupe by `file:line` + category; verdict by rule — verified
   architecture blocker → `refactor-needed`; any other blocker or major → `fix-then-merge`; else
   `merge`. Full report → `.harness/runs/<id>/review.json`; caller receives verdict + top 10 findings.

Scale and failure: 8–10 agents, all top tier (judgment work); wall time ≈ slowest reviewer+verifier
pair. Diffs over ~1,500 changed lines split by module and ask before exceeding the agent budget.
A reviewer that dies is reported `NOT REVIEWED`; the verdict cannot be `merge` with any focus
unreviewed. The review→fix→re-gate loop is not here; it calls this workflow once per round.

## 10. Testing the harness itself

- `gate/` domain: Swift Testing unit tests over fixtures.
- Adapters: tests against recorded real tool outputs (xcresult JSON, `swift package describe`, `simctl list -j`).
- `swiftgate self-test`: fixture repos under `gate/Fixtures/` each seeded with one violation
  (`Date()` in Core, skipped test, record mode on, UIKit in Core, undeclared non-TCA Core, feature importing a `*Live` module, `URLSession.shared` outside `*Live`,
  zero tests executed, retry flag, assertion-free test, tautological test, `try?` in test, unnamed `@Test`, bare `swiftgate:allow`, XCUITest outside `[[flows]]`, surviving mutant) — each must yield `RED`; a clean fixture must yield `GREEN`.
- Hooks: shim tests feeding recorded hook-input JSON and asserting decisions.
- End-to-end: a sample app (`examples/SampleApp`, TCA feature + one engine module) bootstrapped and
  gated at every tier.

## 11. Build order (for the implementation plan)

1. Plugin skeleton + `gate/` package with domain layer, config, module graph (Xcode-agnostic).
2. `lint`, `arch`, `impact`, `self-test` fixtures for them.
3. Hooks (SessionStart, PreToolUse, PostToolUse) on top of 1–2.
4. T1 runner + evidence rules + Stop hook.
5. **Xcode-dependent (unblocked; 26.2 installed):** `XcresultReader` + golden fixtures, T2/T3 runners, sim clone/lock, `snapshots record`, `prove`, `stress`, `doctor`, `gc`, `stats`.
6. `standards.md` + `testing-playbook.md` (after §6.2 verification).
7. Skills + `/swift-bootstrap` + templates; sample app end-to-end.
