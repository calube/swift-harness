# Test fixtures

Every file here is real tool output. Never edit one by hand: re-run its capture command.

Commands run from the repository root. Where output embeds absolute paths, the capture pipes it
through `sed "s#$ROOT#/REPO#g"` (with `ROOT=$(pwd)`) so fixtures carry no machine paths; tests
decode them with repository root `/REPO`.

## SwiftPM

Toolchain: Apple Swift 6.2 (swiftlang-6.2.3.3.20), macOS 26.

| File | Capture |
|---|---|
| `SwiftPM/describe-<Package>.json` (APIClient, CounterFeature, GameEngine, HTTPClient, LogClient) | `(cd examples/SampleApp/Packages/<Package> && swift package describe --type json) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/dump-package-GameEngine.json` | `(cd examples/SampleApp/Packages/GameEngine && swift package dump-package) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/dump-package-main-actor-core.json` | `(cd gate/Fixtures/arch/arch.core-main-actor-isolation/bad/Packages/Feed && swift package dump-package) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/describe-no-package.stderr.txt` | `cd "$(mktemp -d)" && swift package describe --type json` (stderr; exit status 1, empty stdout) |
| `SwiftPM/show-codecov-path-GameEngine.txt` | `(cd examples/SampleApp/Packages/GameEngine && swift test --show-codecov-path) \| sed "s#$ROOT#/REPO#g"` |
| `SwiftPM/xunit-GameEngine.xml`, `SwiftPM/xunit-GameEngine-swift-testing.xml` | `X=$(mktemp -d); (cd examples/SampleApp/Packages/GameEngine && swift test --parallel --xunit-output $X/GameEngine.xml)`, then copy both files `$X` contains |

Observed behavior the adapter relies on:

- `swift package describe` prints the package `path` and local (`fileSystem`) dependency paths as
  absolute paths; target `path`s are package-relative. `product_dependencies` name products
  without their package.
- `describe` omits build settings; `dump-package` reports them per target as
  `settings[].kind.defaultIsolation._0` (`"MainActor"`, or `"nonisolated"` for `nil`) or as
  `unsafeFlags._0` argv. Neither command resolves remote dependencies.
- `--xunit-output <dir>/<stem>.xml` writes XCTest results to that path and Swift Testing results to
  `<dir>/<stem>-swift-testing.xml`. With no XCTest tests, the XCTest file still exists with
  `tests="0"`.
- `--show-codecov-path` prints the absolute path of the llvm-cov export JSON on one line; it does
  not require a coverage build to have run.
| `SwiftPM/describe-XUnitProbe.json` | `(cd gate/Fixtures/swifttest/XUnitProbe && swift package describe --type json) \| sed "s#$ROOT#/REPO#g"` |

## SwiftTest (T1 evidence)

`SwiftTest/<scenario>.{xml,-swift-testing.xml,stdout,stderr,status}` and `SwiftTest/pass-codecov.json`
are captured by `gate/Fixtures/swifttest/capture.sh` (run from the repository root), which runs
`swift test --parallel --xunit-output <dir>/<scenario>.xml --filter <regex>` in
`gate/Fixtures/swifttest/XUnitProbe` and copies whatever the run wrote. A scenario with no `.xml`
file is one where `swift test` wrote none.

| Scenario | Filter | What it shows |
|---|---|---|
| `pass` (with `--enable-code-coverage`) | `ProbeTests\.Pass` | one passing XCTest and one Swift Testing case; `pass-codecov.json` is the llvm-cov export from `--show-codecov-path` |
| `zero-codecov.json` only (with `--enable-code-coverage`) | `^EmptyTests\.` | the llvm-cov export of a run that executes no test: `Probe.swift` instrumented, nothing covered |
| `fail` | `ProbeTests\.Fail` | an `XCTAssertEqual` and an `#expect` failure |
| `skip` | `ProbeTests\.Skip` | `XCTSkip` with and without a message; `.disabled` with and without a reason |
| `shared-first-line` | `ProbeTests\.SharedFirstLine` | two `Issue.record` failures whose console lines both read `Issue recorded`; only the `↳` continuation lines (and the report message) tell them apart |
| `crash` | `ProbeTests\.Crash` | an index-out-of-range trap in each framework |
| `zero` | `^EmptyTests\.` | a target with no tests |
| `build-error` | `ProbeTests\.Pass` | a copy of the package (no build output) with a type error in `Probe.swift` |
| `macro-compile-error` | `ProbeTests\.Pass` | a copy with a `#expect(try …)` call added to `PassTests.swift` inside a non-throwing test: no report, a macro expansion diagnostic with no file:line of its own |
| `reverted` | `ProbeTests\.Pass` | a copy with `double` computing `value * 3`: the passing tests fail on their assertions, as `prove` expects with a source change reverted |
| `compile-only` | `ProbeTests\.Pass` | a copy without the public `double` the tests call: no report, compile errors located in the test files |
| `stale-module-cache` | `ProbeTests\.Pass` | a copy including `.build/`, so the module cache path is stale (recorded as `/MOVED/XUnitProbe`) |

Observed behavior (Swift 6.2, `--parallel`) the evidence rules rely on:

- Both reports are written whenever tests ran: XCTest to `<stem>.xml`, Swift Testing to
  `<stem>-swift-testing.xml`. With `--no-parallel`, SwiftPM writes no XCTest report at all, so T1
  always runs `--parallel`.
- The XCTest report's `<failure message="failure">` is a placeholder. The assertion text and
  `file:line` are only on stdout: `<abs path>:<line>: error: -[<Target>.<Class> <method>] : <text>`.
- The Swift Testing report carries the issue text plus a ` (error)` suffix but no location; stdout
  has `✘ Test <name> recorded an issue at <File.swift>:<line>:<col>: <text>` (file name only).
- Swift Testing reports skips as `<skipped>reason</skipped>` or `<skipped />`. The XCTest report
  records an `XCTSkip` as a pass and stdout says nothing: XCTest skips are invisible under
  `--parallel`.
- A crash leaves the Swift Testing report truncated after `<testsuites>` and prints
  `Fatal error: …`; the XCTest report records the crashing case as a failure. stderr has
  `error: Exited with unexpected signal code 5`.
- A target with no tests yields reports with `tests="0"`, exit status 0, and the stderr warning
  `No matching test cases were run`.
- A compile error writes no report; stderr has `<abs path>:<line>:<col>: error: <text>`. Toolchain
  or cache failures print `<unknown>:0: error: …` instead. A `#expect`/`#require` macro that fails
  to expand (for example `try` in a non-throwing test) prints `macro expansion #<name>:<line>:<col>:
  error: <text>` instead of a file location, followed by `` `- <abs path>:<line>:<col>: note:
  expanded code originates here`` naming the real test file.
- Toggling `--enable-code-coverage` rebuilds the package (about 20s for the SampleApp's TCA
  package), so every T1 run enables it.

`SwiftTest/resolved-file-missing.{stdout,stderr,status}` and
`SwiftTest/resolved-file-stale.{stdout,stderr,status}` are `--only-use-versions-from-resolved-file`
rejecting a package `XUnitProbe` can't reproduce (it has no dependencies), so they come from a
throwaway pair of real git repos instead of `capture.sh`:

```
D=$(mktemp -d); mkdir -p "$D/Dep" "$D/Consumer"
(cd "$D/Dep" && git init -q -b main && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Dep", products: [.library(name: "Dep", targets: ["Dep"])], targets: [.target(name: "Dep")])\n' > Package.swift && mkdir Sources && mkdir Sources/Dep && echo 'public func depHello() -> String { "hello" }' > Sources/Dep/Dep.swift && git add -A && git -c user.name=e -c user.email=e@e commit -qm v1 && git tag 1.0.0)
(cd "$D/Consumer" && git init -q -b main && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Consumer", dependencies: [.package(url: "file://%s/Dep", exact: "1.0.0")], targets: [.target(name: "Consumer", dependencies: [.product(name: "Dep", package: "Dep")])])\n' "$D" > Package.swift && mkdir Sources && mkdir Sources/Consumer && printf 'import Dep\npublic func greeting() -> String { depHello() }\n' > Sources/Consumer/Consumer.swift)
# resolved-file-missing: no Package.resolved at all
(cd "$D/Consumer" && swift test --only-use-versions-from-resolved-file --parallel --xunit-output /tmp/x.xml)
# resolved-file-stale: resolve once, then add a second dependency without re-resolving
(cd "$D/Consumer" && swift package resolve)
mkdir -p "$D/Dep2" && (cd "$D/Dep2" && git init -q -b main && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Dep2", products: [.library(name: "Dep2", targets: ["Dep2"])], targets: [.target(name: "Dep2")])\n' > Package.swift && mkdir Sources && mkdir Sources/Dep2 && echo 'public func dep2Hello() -> String { "hello2" }' > Sources/Dep2/Dep2.swift && git add -A && git -c user.name=e -c user.email=e@e commit -qm v1 && git tag 1.0.0)
(cd "$D/Consumer" && printf '// swift-tools-version: 6.2\nimport PackageDescription\nlet package = Package(name: "Consumer", dependencies: [.package(url: "file://%s/Dep", exact: "1.0.0"), .package(url: "file://%s/Dep2", exact: "1.0.0")], targets: [.target(name: "Consumer", dependencies: [.product(name: "Dep", package: "Dep")])])\n' "$D" "$D" > Package.swift && swift test --only-use-versions-from-resolved-file --parallel --xunit-output /tmp/x.xml)
```

The capture pipes stderr through `sed "s#$D#/FIXTURE#g"` for both; `status` is the exit code (`1`),
`stdout` is empty, and neither writes an xUnit report.

`SwiftTest/emptied-target.{stdout,stderr,status}` is a package whose library target lost every
source file, as a package added since the merge base looks once `prove` reverts its sources.
`XUnitProbe` has no product, and with no product SwiftPM reports a missing module in the tests
instead, so the capture adds a `Probe` library product to a copy and deletes its `Sources`, from the
repository root:

```
W=$(mktemp -d) && mkdir -p "$W/XUnitProbe" && rsync -a --exclude .build plugin/gate/Fixtures/swifttest/XUnitProbe/ "$W/XUnitProbe/" && sed -i '' 's/  platforms: \[.macOS(.v15)\],/&\n  products: [.library(name: "Probe", targets: ["Probe"])],/' "$W/XUnitProbe/Package.swift" && /bin/rm -rf "$W/XUnitProbe/Sources" && (cd "$W/XUnitProbe" && swift test --parallel --xunit-output "$W/emptied-target.xml" --filter 'ProbeTests\.Pass' >"$W/emptied-target.stdout" 2>"$W/emptied-target.stderr"; echo "$?" >"$W/emptied-target.status")
for f in stdout stderr status; do sed "s#$W#/FIXTURE#g" "$W/emptied-target.$f" > plugin/gate/Tests/Fixtures/SwiftTest/emptied-target.$f; done
```

SwiftPM refuses the manifest before building: `status` is `1`, `stdout` is empty, SwiftPM writes no
xUnit report, and stderr ends `error: 'xunitprobe': target 'Probe' referenced in product 'Probe' is
empty` (Swift 6.2).

## Mutation (`mutate`)

`LiveMutationToolchainTests` replays the `SwiftTest` captures above: `swift test --skip-build`
writes the same two xUnit reports as a building `swift test`, and `build-error` stands in for a
rejected `swift build --build-tests` (only its `error:` lines are read).

`gate/Fixtures/mutate` is not captured output but the real package `MutateSelfTests` runs:
`Scorer` at its base commit, `change/Score.swift` (the change under test, nine mutants) and two
suites for it. `weak/` leaves boundary mutants alive, so `mutate` is RED; `strong/` pins every
boundary and return value, so all nine are killed and it is GREEN. The test builds and runs them
for real in scratch worktrees (about 8s each).

## Xcresult (T2/T3 evidence)

Xcode 26.2 (17C48), `xcresulttool` version 24514, schema 0.1.0. The subcommands the gate uses:
`xcrun xcresulttool get test-results tests --path <bundle>` (the test tree) and
`xcrun xcresulttool get build-results --path <bundle>` (build errors). `get test-results summary`
also exists but its failures carry no `file:line`, so the gate does not read it.

`Xcresult/<scenario>.{tests.json,build-results.json,status}` are captured by
`gate/Fixtures/xcresult/capture.sh` (run from the repository root). It clones the pinned
simulator (iPhone 17, iOS 26.2), copies `examples/SampleApp/Packages` to a scratch directory, adds
`gate/Fixtures/xcresult/XcresultProbeTests.swift` to the copy's `CounterUISnapshotTests` target,
and runs `xcodebuild test -scheme CounterFeature-Package -skipMacroValidation
-only-testing:CounterUISnapshotTests/<suite>…` per scenario with `-derivedDataPath` under
`.harness/DerivedData/`. `status` is `xcodebuild`'s exit status. The script replaces the scratch
path with `/SCRATCH`, the clone's UDID with `CLONE-UDID`, its PID with `PID`, and elides the
machine's device list from the "no destination" error; the rest is verbatim.

| Scenario | Selection | What it shows |
|---|---|---|
| `pass` | `CounterViewSnapshotTests` (the real snapshot test), `ProbePassXCTests` | exit 0; both frameworks' cases under a `Unit test bundle` node |
| `fail` | `ProbeFailXCTests`, `ProbeFailSwiftTests`, `ProbePassXCTests` | exit 65; each failure's `Failure Message` is `<File>.swift:<line>: <text>` |
| `skip` | `ProbeSkipXCTests`, `ProbeSkipSwiftTests` | exit 0; skip reasons for both frameworks |
| `crash` | `ProbeCrashXCTests`, `ProbeCrashSwiftTests`, `ProbePassXCTests` | exit 65; the runner restarts after each crash and runs the rest |
| `zero` | `NoSuchSuite` | exit 0; a `Test Plan` node with no children |
| `no-destination` | an all-zero device id | exit 70; empty device, no test nodes, an `Uncategorized` build error |
| `build-error` | `ProbePassXCTests`, with the probe broken to not compile | exit 65; no test nodes; a `Swift Compiler Error` with a `sourceURL` |
| `record` | `CounterViewSnapshotTests`, `ProbeFailXCTests`, with `RECORD=all` (`TEST_RUNNER_SNAPSHOT_TESTING_RECORD=all`) | exit 65; the snapshot case fails with `Issue recorded: Record mode is on. Automatically recorded snapshot: …` beside a real assertion failure |
| `missing-bundle` | `xcresulttool` against a path that does not exist | `.stderr` + `.status` per subcommand (exit 64) |

`Xcresult/ui-pass.{tests,build-results}.json` are captured by `gate/Fixtures/xcresult/capture-ui.sh`
(run from the repository root): a real `swiftgate test --tier t3` of the SampleApp's app scheme
(its one XCUITest, `CounterFlowUITests`), read back with the same two `xcresulttool` subcommands.
The repository path becomes `/REPO`, the clone's name `swift-harness-PID-TOKEN` and its UDID
`CLONE-UDID`. It shows XCUITest cases under a `UI test bundle` node, identified
`<Class>/<method>()`.

`plugin/gate/Fixtures/xcresult/capture-app-build.sh` captures
`Xcresult/app-build-{pass,error}.build-results.json`: a scratch git copy of `examples/SampleApp`
runs `swiftgate check --tier fast --base HEAD --app-build` as committed (`pass`, GREEN), then again
with a commit that adds `static let broken: Int = "not a number"` to `App/SampleApp.swift`
(`error`, RED, `--base HEAD~1`). The script reads each back with
`xcrun xcresulttool get build-results` from the run's `app-build/SampleApp.xcresult`. The scratch path becomes `/SCRATCH`, in both its
`/private/var` and its `/var` spelling: xcodebuild blames files under `/var`. A generic
`iOS Simulator` build bundle holds build results and no test tree.

Observed behavior the evidence rules rely on:

- Unlike host `swift test --parallel`, the bundle records XCTest skips, with reasons. XCTest:
  `Test skipped` or `Test skipped - <reason>`. Swift Testing: `Test '<name>' skipped` or
  `Test '<name>' skipped: <reason>`.
- A failure's location is a file name only; the rules resolve it against the selected targets'
  sources.
- A crash's message starts `Crash: `. Swift Testing crashes name `file <File>.swift line <n>`;
  XCTest crashes name only the crashing symbol.
- A build error's `sourceURL` is `file://<abs path>#…&StartingLineNumber=<0-based>&…`.
- An unresolved destination records a device whose `deviceId` is empty.

## Doctor

Captured on the machine the gate was built on (Xcode 26.2):
`xcodebuild -version > Doctor/xcodebuild-version.txt`, `swift --version > Doctor/swift-version.txt`
(both verbatim), and `Doctor/Package.resolved-CounterFeature.json`, a verbatim copy of
`examples/SampleApp/Packages/CounterFeature/Package.resolved` (format version 3).

## Simctl

`Simctl/<call>.{stdout,stderr,status}` are captured by `gate/Fixtures/simctl/capture.sh` (run from
the repository root): each file is one real `xcrun simctl` call against a throwaway clone of the
pinned simulator (`clone`, `list-devices` while the clone exists, `bootstatus -b`, `launch` of
`com.apple.Preferences`, `install` of a missing app, `shutdown`, `delete`), plus `clone` and `delete`
of an all-zero UDID. The scratch path is replaced with `/SCRATCH`.

- `simctl clone` prints only the new UDID; `launch` prints `<bundle id>: <pid>`.
- An unknown device exits 148 with `Invalid device: <udid>`.
- `bootstatus -b` boots the device and exits once it has finished booting.

`plugin/gate/Fixtures/simctl/capture-booted-base.sh` (run from anywhere) captures
`Simctl/{clone-booted,create,list-devices-booted-base}.{stdout,stderr,status}`. It creates a
throwaway `swiftgate capture base` (iPhone 17, iOS 26.2), boots it with `bootstatus -b`, then records
`clone <base> swift-harness-<pid>-booted`, `create swift-harness-<pid>-created
com.apple.CoreSimulator.SimDeviceType.iPhone-17 com.apple.CoreSimulator.SimRuntime.iOS-26-2`, and
`list devices --json` while the base runs and the created device exists. On exit it shuts down
and deletes only the devices it made.

- `simctl clone` of a booted device exits 149 with `SimError` code 405, `Unable to clone device in
  current state: Booted`, and makes nothing.
- `simctl create` prints only the new UDID. The device list gives each device's
  `deviceTypeIdentifier`.

## SwiftFormat

Toolchain `swift format` 6.2.1. Sources under `gate/Fixtures/format/` (excluded from the harness's
own gate) are the inputs.

| File | Capture |
|---|---|
| `SwiftFormat/lint-strict.stderr`, `SwiftFormat/lint-strict.status` | `(cd gate/Fixtures/format && swift format lint --strict Formatted.swift Unformatted.swift Broken.swift) 2>&1 >/dev/null \| sed "s#$ROOT#/REPO#g"`; the status file holds the exit status |

Observed behavior the adapter relies on:

- Diagnostics go to stderr as `<path>:<line>:<column>: error: [<Rule>] <message>` (`warning:`
  without `--strict`), with the path as given on the command line. A file that does not parse is
  reported with its absolute path and no `[Rule]`.
- Exit status is 1 when any diagnostic is printed under `--strict`, else 0. A path that does not
  exist is silently skipped with status 0, so the gate passes only existing files.

## Hooks

`Hooks/*.json` are Claude Code hook stdin payloads. Seven are captured from live headless
sessions (Claude Code 2.1.282, 2026-09-25) in a bootstrapped SampleApp copy, with the plugin
loaded by `--plugin-dir` and recording on:

```
SWIFTGATE_HOOK_RECORD_DIR=<dir> claude -p '<prompt>' --plugin-dir <harness checkout> \
  --permission-mode acceptEdits --setting-sources project,local \
  --output-format stream-json --verbose --include-hook-events
```

`session-start`, `pre-tool-use-bash-xcodebuild` (prompt: run a raw `xcodebuild … test`),
`pre-tool-use-edit-swift`, `post-tool-use-edit-swift`, `stop`, `stop-reentry` (prompt: add a
literal `Date()` to CounterCore's reducer and stop without fixing) and `pre-tool-use-bash-allowed`
(a `swiftgate check` the model ran). Scrubbing: the repository path becomes `/REPO`, the
transcript directory `/HOME/.claude/projects/-REPO/`, and every `session_id` the fixed
`8f2c1d7e-…` the tests key on; nothing else changed.

`pre-tool-use-bash-reviewer-span` is a review agent's span line, captured the same way (Claude
Code 2.1.288, 2026-10-04) from a scratch git repository with no `.swiftgate.toml`, which changes
nothing in the payload:

```
SWIFTGATE_HOOK_RECORD_DIR=<dir> claude -p "Use the Agent tool exactly once, with subagent_type \
  swift-harness:verifier, and this prompt: 'Run exactly this one Bash command, once, verbatim, \
  and reply with its output and nothing else: <plugin>/bin/swiftgate events span start --phase \
  verify --build-run 20261004-capture --task 'reviewer-span' --role review'. Then reply done." \
  --plugin-dir <plugin> --permission-mode acceptEdits --setting-sources project,local \
  --output-format stream-json --verbose --include-hook-events
```

It shows a plugin subagent's PreToolUse carries `agent_id` and `agent_type`
`swift-harness:verifier`. Scrubbed as above, and the plugin directory became `/PLUGIN`; the JSON
was re-indented.

The rest (`pre-tool-use-bash-git-commit`, `pre-tool-use-edit-snapshot`,
`pre-tool-use-write-*`, `post-tool-use-write-markdown`, `session-start-resume`) are still built
from the documented schema: no live session produced a Write, a subagent or a resume. Tests swap
`/REPO` for a probe repository. Re-record whenever Claude Code's hook contract changes.

Live payloads differ from the documented examples only in fields swiftgate does not read:
SessionStart has no `model` in a headless session; Bash `tool_input` omits `timeout` and
`run_in_background` unless the model sets them; PostToolUse carries `effort` and a full
`tool_response` (`originalFile`, `structuredPatch`, `oldString`, `newString`, `replaceAll`,
`userModified`).

Sources, fetched 2026-09-24 as Markdown (`curl -sL <url>.md`):

- Hooks reference, https://code.claude.com/docs/en/hooks — common input fields; SessionStart,
  PreToolUse (Bash/Edit/Write `tool_input`), PostToolUse and Stop inputs; JSON output and decision
  control; exit-code semantics; timeouts.
- Plugins reference, https://code.claude.com/docs/en/plugins-reference, and plugin components,
  https://code.claude.com/docs/en/plugins/components — `hooks/hooks.json` format and
  `${CLAUDE_PLUGIN_ROOT}`.

Contract points the hooks rely on:

- Every payload has `session_id`, `transcript_path`, `cwd`, `hook_event_name`; tool events add
  `tool_name`, `tool_input`, `tool_use_id`. File-tool `tool_input.file_path` is always absolute.
- Inside a subagent every event also carries `agent_id` (and `agent_type`); the main thread never
  does. That is how a worker is told apart from the orchestrator.
- Stop carries `stop_hook_active`: `true` when Claude is continuing because a Stop hook blocked.
  Claude Code ends the turn itself after 8 consecutive blocks; swiftgate releases after 3.
- A hook decides by exiting 0 with JSON on stdout. PreToolUse denies with
  `hookSpecificOutput.permissionDecision: "deny"` plus `permissionDecisionReason` (shown to
  Claude). PostToolUse and Stop use top-level `decision: "block"` with `reason`.
  `hookSpecificOutput.additionalContext` adds context (SessionStart, PreToolUse, PostToolUse);
  `systemMessage` shows the user a message without continuing the turn.
- Exit 2 also blocks, with stderr as the reason; any other non-zero exit is a non-blocking error,
  so swiftgate uses exit 1 only for a malformed payload. A hook that times out renders no
  decision, and on PreToolUse the call proceeds.
- `additionalContext`, `systemMessage` and plain stdout are capped at 10,000 characters.
- Plugin hooks live in `hooks/hooks.json` under a top-level `hooks` key, in the `settings.json`
  shape. With `args` set, the hook runs in exec form: `command` and each `args` element have
  `${CLAUDE_PLUGIN_ROOT}` substituted and no shell is involved. `timeout` is in seconds
  (default 600 for command hooks).

## Bootstrap

Xcode 26.2 (17C48), run from `examples/SampleApp`:

| File | Capture |
|---|---|
| `Bootstrap/xcodebuild-list-project.json` | `xcrun xcodebuild -list -json -project SampleApp.xcodeproj` (verbatim stdout, exit 0) |
| `Bootstrap/xcodebuild-list-missing.{stdout,stderr,status}` | `xcrun xcodebuild -list -json -project Missing.xcodeproj`; the result-bundle path under the user temp directory is replaced with `/TMP/` |

Observed behavior the adapter relies on:

- A project listing is `{"project": {"name", "schemes", "targets", "configurations"}}`. Package
  products of local packages appear as schemes beside the app's, so the app scheme is the one named
  after the project, or else the only scheme that is also a target.
- Listing resolves the project's packages first (16s cold on the sample app).
- A missing project exits 66 with the error on stderr.

## Judge

Claude Code 2.1.282, run from a scratch directory with the schema in
`Judge/claude-capture-schema.json` (the shape `ClaudeJudgePrompt.schema` builds for a one-question
set) and the prompt in `Judge/claude-capture-prompt.txt` on stdin:

| File | Capture |
|---|---|
| `Judge/claude-result.json` | `claude -p --output-format json --json-schema "$(cat claude-capture-schema.json)" --restricted --tools "" --strict-mcp-config --no-session-persistence --model haiku < claude-capture-prompt.txt` (verbatim stdout, exit 0) |
| `Judge/claude-unknown-model.json` | the same with `--model no-such-model` (verbatim stdout, exit 1; stderr was `[claude-code:unrecognized_model] {"model":"no-such-model","query_source":"sdk"}`) |

Observed behavior the adapter relies on:

- `--output-format json` prints one result envelope. With `--json-schema` the validated reply is
  the `structured_output` object (and also JSON text in `result`).
- A failed call still prints an envelope, with `is_error: true` and the message in `result`, and
  exits 1.
- `--restricted` ignores user, project and local settings (so plugin hooks don't run inside the
  judge) and `--tools ""` removes every built-in tool.

## Jev

TypeSafe's `POST https://api.typesafe.ai/v1/systemone`, captured 2026-09-30 with `curl` 8.7.1 and
the user's key in `TYPESAFE_API_KEY`. Each command runs from `plugin/gate/Tests/Fixtures/Judge`
under `bash`; the key reaches `curl` through a process substitution, so it never appears in an
argument list, and the capture keeps no request or response headers. `<name>` is the file stem below.

```sh
curl -sS -o jev-<name>.reply.json -w '%{http_code}\n' \
  -H @<(printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY") \
  -H 'Content-Type: application/json' \
  --data-binary @jev-request-<name>.json https://api.typesafe.ai/v1/systemone > jev-<name>.status
```

A script builds the request inputs from real subjects, in the shape design §4.1 gives:
`state` holds `subject_kind` (the question set's `subjectDescription`), `subject`, `context` and,
for tests, `declared_tier`; each question's `instructions` is its `JudgeQuestion.text` unchanged.

| Request | Subject | Questions |
|---|---|---|
| `jev-request-test-quality.json` | `gate/Fixtures/judge/cases/counter-increment` (`Test.swift.txt` as `subject`, `Change.diff` as `context`), `declared_tier` `T1` | `test-quality@1`: 2 Noul, 1 Choice (`criteria` `{T1: null, T2: null, T3: null}`), 1 Score (`criteria` `["vague", "partial", "specific"]`) |
| `jev-request-alias.json` | the same for `own-double`, with `model` `jev-latest` | `test-quality@1` |
| `jev-request-invalid.json` | `own-double` | only `tier`, a Choice with its `criteria` removed |
| `jev-request-comments.json` | the comment `// Length-prefixing each field …` in `plugin/gate/Sources/SwiftGateDomain/Judge/Judge.swift` as it reads at commit `618c180`, with the 6 lines after it as `context` (the commit comment judge's slice) | `comments@1`: 2 Noul |

| File | Capture | Status | Served `model` |
|---|---|---|---|
| `jev-test-quality.reply.json`, `.status` | the command above, `<name>` = `test-quality` | 200 | `jev-1.13.0` |
| `jev-comments.reply.json`, `.status` | `<name>` = `comments` | 200 | `jev-1.13.0` |
| `jev-alias.reply.json`, `.status` | `<name>` = `alias` (requests `jev-latest`) | 200 | `jev-1.13.0` |
| `jev-invalid.reply.json`, `.status` | `<name>` = `invalid` | 422 | none |
| `jev-bad-key.reply.json`, `.status` | `TYPESAFE_API_KEY=invalid`, then the command with `-o jev-bad-key.reply.json`, `--data-binary @jev-request-test-quality.json` and `> jev-bad-key.status` | 401 | none |
| `jev-oversize.reply.json`, `.status` | the request isn't kept (157 KB): `git ls-tree -r --name-only 1075aa6 -- ../../../Sources/SwiftGateDomain \| grep '\.swift$' \| sort \| while read p; do git show "1075aa6:$p"; done \| python3 -c 'import json,sys; r=json.load(open("jev-request-test-quality.json")); r["state"]["subject"]=sys.stdin.read()[:150000]; json.dump(r,open(sys.argv[1],"w"))' "$TMPDIR/jev-request-oversize.json"`, then the command with `--data-binary @"$TMPDIR/jev-request-oversize.json"` and `-o jev-oversize.reply.json`, `> jev-oversize.status` | 400 | none |

Observed behavior the adapter relies on:

- A `.status` file holds the HTTP status and a newline; the reply body is what the server sent,
  byte for byte, compact JSON with no trailing newline.
- The server answers `jev-latest` with `jev-1.13.0`: the reply's `model` is the resolved id, never the alias.
- Question keys with hyphens (`fails-if-broken`, `name-specificity`) come back unchanged as the
  keys of `answers`. The server may reorder the options inside `probabilities` (`T3` came first).
- A Noul answer is `{"type": "noul", "noul": p}`, with no `confidence`.
- A Choice answer is `{"type": "choice", "choice", "confidence", "probabilities"}`, with
  `probabilities` keyed by the option names sent in `criteria`.
- A Score answer is `{"type": "score", "score", "confidence", "legend", "probabilities"}`.
  The level index, as a string, keys `legend` and `probabilities`, `"0"` first, and
  `legend["i"]` is the text of level `i` in the order `criteria` listed them. `score` is the
  probability-weighted index and `confidence` can be 0 while `probabilities` are spread.
- No answer carries a reason, rationale or any text beyond the option and level names.
- `usage` is `{"input_tokens", "output_tokens"}`; output tokens appear even though TypeSafe
  prices them at 0.
- A 422 body is `{"detail": [{"type", "loc", "msg", "input"}]}`, and `loc` names the question key
  and the missing field (`["body", "questions", "tier", "choice", "criteria"]`).
- A bad key is 401 with `{"detail": {"error_type": "authentication_error", "message"}}`.
- A state over the model's limit is 400, not 422, with `{"detail": {"error_type":
  "max_tokens_exceeded"}}` and no count; the adapter's own estimate refuses it before sending.

### `test-quality@2-jev` and described Score levels

Captured 2026-09-30 17:39 UTC with the same `curl`, key and command as above (design §13.2 to §13.4).
The request inputs come from code, not by hand. `test_name` and `assertions` are what the gate's
own parser returns: `SwiftGateDomain/Judge/JudgeTestSubjectParts.swift` compiled on its own into a
helper that reads a test's source on stdin.

```sh
cat > "$SCRATCH/main.swift" <<'SWIFT'
import Foundation
let source = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
struct Parts: Encodable {
  let test_name: JudgeTestName
  let assertions: [String]
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
let parts = Parts(test_name: JudgeTestName.parse(source: source), assertions: JudgeAssertions.extract(source: source))
FileHandle.standardOutput.write(try encoder.encode(parts))
SWIFT
swiftc -O -o "$SCRATCH/judge-parts" \
  ../../../Sources/SwiftGateDomain/Judge/JudgeTestSubjectParts.swift "$SCRATCH/main.swift"
python3 "$SCRATCH/build_requests.py" "$SCRATCH/judge-parts" "$(git rev-parse --show-toplevel)"
```

`build_requests.py`, run from this directory:

```python
import json, subprocess, sys

parts_tool, root = sys.argv[1], sys.argv[2]
cases = root + "/plugin/gate/Fixtures/judge/cases/"
study = json.load(open(root + "/evals/results/2026-09-30-jev-question-design/questions.json"))
base = json.load(open("jev-request-test-quality.json"))


def sub_questions():
    out = {}
    for q in study["questions"]:
        for sub in q["jev"]["subQuestions"]:
            key = q["id"] if q["id"] == "tier" else q["id"] + "." + sub["id"]
            body = {k: v for k, v in sub.items() if k != "id"}
            if q["id"] == "tier":
                body = dict(base["questions"]["tier"])
            out[key] = body
    return out


def native(case):
    source = open(cases + case + "/Test.swift.txt").read()
    parts = json.loads(subprocess.run([parts_tool], input=source.encode(), capture_output=True, check=True).stdout)
    state = {
        "subject_kind": base["state"]["subject_kind"],
        "test_name": {k: parts["test_name"].get(k) for k in ("full", "behavior", "catches")},
        "test_source": source,
        "assertions": parts["assertions"],
        "code_under_test": open(cases + case + "/Change.diff").read(),
        "declared_tier": "T1",
    }
    return {"model": base["model"], "state": state, "questions": sub_questions()}


def levels():
    request = json.loads(json.dumps(base))
    question = request["questions"]["name-specificity"]
    clauses = question["instructions"].split("? ", 1)[1].rstrip(".").split("; ")
    assert [c.split(":")[0] for c in clauses] == question["criteria"], clauses
    question["criteria"] = clauses
    return request


def write(name, request):
    with open("jev-request-" + name + ".json", "w") as f:
        json.dump(request, f, indent=2, ensure_ascii=False)
        f.write("\n")


write("test-quality-2-jev-good", native("counter-increment"))
write("test-quality-2-jev-useless", native("own-double"))
write("test-quality-levels", levels())
```

The sub-questions come from the study's `questions.json` unchanged, and equal the JSON block in
design §13.3 key for key. Both cases declare `T1` in `gate/Fixtures/judge/labels.json`. `tier` is
the `@1` question as the adapter already sends it.

| Request | Subject | Questions |
|---|---|---|
| `jev-request-test-quality-2-jev-good.json` | `counter-increment`: `test_source` from `Test.swift.txt`, `code_under_test` from `Change.diff`, `declared_tier` `T1` | `test-quality@2-jev`: 6 sub-questions keyed `<question id>.<sub-question id>` (5 Noul, 1 Choice) and `tier` |
| `jev-request-test-quality-2-jev-useless.json` | `own-double`, the same way | the same |
| `jev-request-test-quality-levels.json` | `jev-request-test-quality.json` with only `name-specificity`'s `criteria` changed: each level with its clause from the question's text, as in `"vague: names no symptom or restates the behavior"` | `test-quality@1` |

| File | Capture | Status | Served `model` |
|---|---|---|---|
| `jev-test-quality-2-jev-good.reply.json`, `.status` | `<name>` = `test-quality-2-jev-good` | 200 | `jev-1.13.0` |
| `jev-test-quality-2-jev-useless.reply.json`, `.status` | `<name>` = `test-quality-2-jev-useless` | 200 | `jev-1.13.0` |
| `jev-test-quality-levels.reply.json`, `.status` | `<name>` = `test-quality-levels` | 200 | `jev-1.13.0` |

Observed behavior the `@2-jev` rendering relies on:

- Dotted question keys (`fails-if-broken.runs-changed-code`) come back unchanged as the keys of
  `answers`, in the order sent; `tier` sits beside them under its own id.
- The server takes a Noul with an object `instructions` (`question` and `focus`) and object
  `criteria` (`true`/`false` with `what`, `examples` or `not_for`), and a Noul with no `criteria`
  (`log-text`). A Choice keyed by option names with object values answers with `probabilities`
  keyed by those names.
- The combination rules separate the 2 cases: `fails-if-broken` gives `p_no` 0.06 for
  `counter-increment` and 0.90 for `own-double` (from `runs-changed-code` 0.1), and
  `asserts-implementation` gives `p_yes` 0.11 and 0.05.
- `name-specificity.catches-adds` answers `condition` (0.79) for `counter-increment`, whose
  label is `specific`, and `nothing` (0.90) for `own-double`.
- A Score `legend` echoes each level string as sent, byte for byte, description included:
  `legend["0"]` is `"vague: names no symptom or restates the behavior"`. A legend check compares
  it with the sent strings, not the bare level names.
- `usage.output_tokens` is 203 for both `@2-jev` requests and 99 for both `@1` requests, so it
  tracks the question count, not the answers.

### `diff-risk@1` and `finding-severity@1`

Captured 2026-10-04 03:47 UTC with the same `curl`, key and command as above (design §11.5).
Each request is the body `JevJudge` sent a `FakeHTTPTransport` for `DiffRisk.subject` or
`FindingSeverity.subject`, written with sorted keys. `JevClassifyingCaptureTests` rebuilds each subject and checks the
adapter still sends that body.

The diff-risk subjects are commits of this repository, as `LiveGit.unifiedDiff` renders them,
with the touched paths from `git diff --name-only --find-renames <sha>~1 <sha>`:

```sh
git diff --unified=3 --no-color --no-ext-diff --no-textconv --find-renames \
  --src-prefix=a/ --dst-prefix=b/ <sha>~1 <sha>
```

| Request | Subject | Reply level |
|---|---|---|
| `jev-request-diff-risk-docs.json` | `3510eed9` (docs only) | `low` (0.96) |
| `jev-request-diff-risk-thresholds.json` | `b26bd062` (judge threshold defaults) | `medium` (0.88) |
| `jev-request-diff-risk-path-leak.json` | `d9c59620` (a missing command no longer prints `PATH`) | `medium` (0.70) |
| `jev-request-diff-risk-egress.json` | `16c7d9b8` (the Jev judge requires `send_to`); built from `jev-request-diff-risk-docs.json` with `state.subject` and `state.context` replaced by a script, and checked equal to the adapter's body by the test | `high` (0.95) |
| `jev-request-finding-severity-cancel.json` | `Review/dismiss-race/concurrency.json` finding 0 (rule, file, line, title, failure scenario; its `severity` is never sent), with `Review/dismiss-without-cancel.patch` as context | `major` (0.71) |
| `jev-request-finding-severity-loading.json` | `Review/dismiss-race/test-quality.json` finding 1, the same way | `minor` (0.46, `major` 0.45) |

Each reply is `jev-<name>.reply.json` with `jev-<name>.status`, `<name>` the request's stem; every
status is 200 and the served `model` is `jev-1.13.0`. No reply carries the key; `grep -F` for the
key over this directory finds nothing.

Observed behavior the classifying sets rely on:

- A single Score question with described levels answers under its own key (`risk`, `severity`),
  `legend` echoing each described level and `probabilities` keyed `"0"` (the worst level) up.
- `usage.output_tokens` is 17 for every request, 1 Score question each.
- The 1-line `PATH` leak fix rates `medium`, not `high`: a sensitive path list, not Jev, is what
  makes a change `high` for sure.

## Review

| File | Capture |
|---|---|
| `Review/d7-api-errors.json`, `Review/d7-architecture.json` | Verbatim copies of `review-findings/api-errors.json` and `review-findings/architecture.json` from a real run of `workflows/review.js` on the SampleApp "Review input" change (see `docs/e2e-report.md`). Neither file contains a machine path, so nothing was scrubbed. |

Observed behavior synthesis relies on: two reviewers citing the same rule at the same line invent
different `category` strings (`live-client-logic`, `logic-in-live-client`), so standards
violations dedupe on `rule`, not `category`.

| File | Capture |
|---|---|
| `Review/dismiss-race/{api-errors,architecture,concurrency,test-quality}.json` | Verbatim copies of `review-findings/<focus>.json` from the swift-harness-evals `review-dismiss-without-cancel` trial of 2026-09-27 (evals-round-7, `/swift-harness:review` at harness `2f39ae8`). No machine path appears in them. |
| `Review/dismiss-without-cancel.patch`, `Review/clean-reset.patch` | `examples/SampleApp` copied to a scratch directory, `git init` + commit, then the evals case's `change.patch` applied and committed, then the exact diff `LiveGit.unifiedDiff` runs: `git diff --unified=3 --no-color --no-ext-diff --no-textconv --relative --find-renames --src-prefix=a/ --dst-prefix=b/ HEAD~1 -- .`. Tests render them with `NumberedDiff.render` to get `diff-numbered.txt`. |

| File | Capture |
|---|---|
| `Review/dismiss-rule-pair/{concurrency,api-errors}.json` | Verbatim copies of `review-findings/<focus>.json` from the swift-harness-evals `review-dismiss-without-cancel` trial of 2026-09-27 (the review-accuracy confirming run, `/swift-harness:review` at harness `0a99c70`, run `20260927T151548Z-aabadbfd`), taken from that trial's `kept/.harness/runs/<run>/review-findings/`. No machine path appears in them. |

Observed behavior synthesis relies on: the concurrency reviewer filed the dismiss race as a `defect`
that cites rule `C3`. The api-errors reviewer filed the same race at the same lines and
`severity_rule` as a `defect` with no rule and another category (`api-misuse`). So a defect may
carry a rule, and a rule-less copy of a finding must never replace the copy that cites one.

Observed behavior synthesis relies on: 1 user-visible race came back from 4 reviewers at
`CounterFeature.swift` lines 67, 69, 69 and 70 under the categories `missing-effect-cancellation`,
`missing-cancellation`, `effect-lifetime` and `missing-edge-case`. So defects merge across a
3-line window, and the cancellation names share a canonical category.

## DesignTelemetry

| File | Capture |
|---|---|
| `DesignTelemetry/research-result.json`, `DesignTelemetry/research-result-no-budget.json` | `DESIGN_TELEMETRY_CAPTURE_DIR=plugin/gate/Tests/Fixtures/DesignTelemetry mise exec node@24 -- node tests/design_research_workflow_test.mjs` |
| `DesignTelemetry/review-result.json`, `DesignTelemetry/review-result-no-budget.json` | `DESIGN_TELEMETRY_CAPTURE_DIR=plugin/gate/Tests/Fixtures/DesignTelemetry mise exec node@24 -- node tests/design_review_workflow_test.mjs` |

Each file is the return value of the real `workflows/design-research.js` or
`workflows/design-review.js`, run by the node test's harness. The harness stubs the lane and
reviewer agents and the runtime's `budget`: each stub call adds a fixed count to
`budget.spent()`, and the `-no-budget` files ran with no `budget` in scope. So the `telemetry`
block is the script's own output, and its token counts are the stubs' counts, not a model's.

## Probe

Apple Swift version 6.2 (swiftlang-6.2.3.3.20 clang-1700.6.3.2), `arm64-apple-macosx26.0`.
`Probe/<scenario>.{stdout,status}` are `swift build` runs of a scratch package outside the repo
(stderr was empty for every scenario, so it is not captured). Each probe file is named after the
enum it declares, `Probe_<id>.swift`, per spec §6.2 — `swiftgate probe` attributes a diagnostic
back to its claim by matching the diagnostic's file name against this convention.

```
SCRATCH=$(mktemp -d)
mkdir -p "$SCRATCH/Sources/ProbeScratch"
cat > "$SCRATCH/Package.swift" <<'SWIFT'
// swift-tools-version:6.2
import PackageDescription

let package = Package(
  name: "ProbeScratch",
  targets: [
    .target(name: "ProbeScratch")
  ]
)
SWIFT
cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_good_effect_cancel.swift" <<'SWIFT'
enum Probe_ev_good_effect_cancel {
  static func run() -> Int { 1 + 1 }
}
SWIFT
cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_warns_but_compiles.swift" <<'SWIFT'
enum Probe_ev_warns_but_compiles {
  static func run() -> Int {
    let unused = 42
    return 1
  }
}
SWIFT
# good.{stdout,status}: swift build here (only the two files above)

cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_fabricated_symbol.swift" <<'SWIFT'
enum Probe_ev_fabricated_symbol {
  static func run() -> Int {
    fabricatedAPIThatDoesNotExist()
  }
}
SWIFT
cat > "$SCRATCH/Sources/ProbeScratch/Probe_ev_wrong_signature.swift" <<'SWIFT'
enum Probe_ev_wrong_signature {
  static func run() -> Bool {
    "abc".hasPrefix(5)
  }
}
SWIFT
rm -rf "$SCRATCH/.build"
# mixed.{stdout,status}: swift build here (all four probe files above)

cat > "$SCRATCH/Sources/ProbeScratch/Extra.swift" <<'SWIFT'
let extraSyntaxError: Int =
SWIFT
rm -rf "$SCRATCH/.build"
# unattributed.{stdout,status}: swift build here (the four probes plus Extra.swift, which
# is not a probe file — its errors match no `Probe_<id>.swift` name)
```

Each build's absolute scratch path is replaced with `/SCRATCH`.

| Scenario | Probe files | What it shows |
|---|---|---|
| `good` | good, warns | exit 0; the only diagnostic is the `warns` probe's warning |
| `mixed` | good, warns, fabricated, wrong-signature | exit 1; `fabricated` and `wrong-signature` each fail with one `error:` in their own file only; `good` and `warns` have no error |
| `unattributed` | mixed + `Extra.swift` (not a probe) | exit 1; `Extra.swift`'s syntax error recurs once per compile job, attributable to no claim |

Observed behavior the domain relies on:

- A diagnostic's primary line is `<abs path>:<line>:<col>: error|warning: <message>`, optionally
  suffixed `[#<category>]` on a warning; the following source-snippet and caret-continuation lines
  carry no `path:line:col:` prefix, so a line-anchored match never mistakes them for a diagnostic.
- Diagnostics print on stdout, not stderr, under plain `swift build`.
- A parse error in one file is re-emitted once per remaining compile job in the same invocation
  (`unattributed.stdout` shows `Extra.swift`'s error five times) — attribution must not assume one
  diagnostic per file, and a probe's own single real error must not be mistaken for several.
- A warning never fails its build (`good.status` is `0`); only `error:` lines do.

### `swiftgate probe` on the iOS simulator

Xcode 26.2 (17C48), iphonesimulator SDK 26.2. `Probe/ios-sampleapp.{stdout,status}` are one real
`swiftgate probe --json` run against the SampleApp's `CounterFeature` package (target
`CounterCore`, swift-composable-architecture 1.26.2), with the two snippets in
`gate/Fixtures/probe/ios-snippets/`: a `@Reducer` feature (real TCA API, passes) and
`Effect<Int>.teleport(to:)` (fabricated, fails). stderr held only the shim's own build log, so it
is not captured. Run from the repository root with a cold `.harness/probe/` and an empty cache
home; wall time was 80s including a 36s rebuild of `swiftgate` by the shim:

```sh
mkdir -p docs/designs/probe-sampleapp.evidence/probes
cp gate/Fixtures/probe/ios-snippets/*.snippet.swift docs/designs/probe-sampleapp.evidence/probes/
HOME_DIR=$(mktemp -d)
bin/swiftgate probe --design docs/designs/probe-sampleapp.md \
  --package examples/SampleApp/Packages/CounterFeature --target CounterCore \
  --cache-home "$HOME_DIR" --json > gate/Tests/Fixtures/Probe/ios-sampleapp.stdout
echo $? > gate/Tests/Fixtures/Probe/ios-sampleapp.status
rm -rf docs/designs/probe-sampleapp.evidence
```

The output holds no machine path: diagnostics are recorded against the evidence-relative wrapper
(`probes/Probe_<id>.swift`), which has the same line numbers as the scratch copy `xcodebuild`
compiled. The local `APIClient` and `LogClient` products are left out with a note.

## DesignSha

git 2.50.1 (Apple Git-155). `DesignSha/*.md` are the inputs, not tool output: each
`<variant>-approved.md` is a design doc, and `<variant>.stripped.md` is the same doc with its
frontmatter `status:` line removed by hand, so the expected sha never comes from the code under
test. `lf-proposed.md` differs from `lf-approved.md` only in its status value. Variants: `lf`,
`crlf` (every line ends `\r\n`), `no-trailing-newline`, `non-ascii` (Latin accents, CJK, an emoji),
and `fenced-status-edited`, whose body has a `status:` line inside a fenced block that must stay
hashed. `DesignSha/.gitattributes` sets `-text` so checkout never rewrites the line endings.

`DesignSha/hashes.txt` is the captured output, `<sha> <file>` per line, from a real temp repo:

```sh
cd gate/Tests/Fixtures/DesignSha
T=$(mktemp -d) && cp .gitattributes *.md "$T"/ && cd "$T"
git init -q -b main && git add -A && git -c commit.gpgsign=false commit -qm fixtures
for f in *.md; do
  h=$(git hash-object --no-filters "$f")
  [ "$h" = "$(git rev-parse "HEAD:$f")" ] || echo "MISMATCH $f"   # stored blob == raw bytes
  printf '%s %s\n' "$h" "$f"
done > hashes.txt
```

Copy `hashes.txt` back. The loop printed no `MISMATCH`: every committed blob equals the raw bytes.

## Surface (`surface-check`)

git 2.50.1 (Apple Git-155). `surface/capture.sh` builds a temp repository and commits a base tree.
It then commits each case on its own branch from that base and records what
`LiveSurfaceCommitReader` consumes:

- `surface/cases/<case>/changed.txt` is `git diff --name-only --no-renames <base> <case>`.
- `surface/cases/<case>/{parent,commit}/<path>.txt` is `git show <rev>:<path>` of each changed
  Swift path on each side that holds it.
- `surface/parent-tree/<path>.txt` is every Swift file in the base tree, the input to
  `parentSwiftSources`.

The case bodies are inputs, written in the script; every recorded file is git's output. Swift text
carries a `.txt` suffix so no Swift tool lints or builds it.

```sh
plugin/gate/Tests/Fixtures/surface/capture.sh
```

`allowed-*` cases are the false-negative list: each allowed stub form, including every empty
default, accessors, initializers, `throws`/`async` functions, forwards, reducers, views, previews,
closure properties and a new enum case's branch. `allowed-no-new-bodies` changes Swift only by a
deletion and a reformatted body. `rejected-*` cases are the false-positive list: bodies shaped like
stubs that carry behaviour.

`allowed-throw-only`, `allowed-empty-payload-case` and `allowed-returns-unchanged` hold the 3 stub
shapes real surface commits use: a body that only throws an error value, an enum case built from
empty defaults or parameters, and a parameter or property of `self` returned unchanged. Each has a
near miss that must still fail: `rejected-throw-near-miss`, `rejected-payload-case-near-miss` and
`rejected-returns-near-miss`. The base tree's `Status.swift` declares the payload enums they
construct. The same capture command records them.

`allowed-manifest-local-package` is the rehearsal's surface: an existing manifest gains a local
package, its product and a target, beside a new package's manifest.
`allowed-manifest-products-and-targets` adds a URL package, a library, targets and a target name.
The `rejected-manifest-*` near misses remove a dependency, change an element's version, add a
flag to `swiftSettings`, change a platform, change the tools version and add a statement. The
base tree's `Packages/AppFeature/Package.swift` is the manifest they edit. The same capture
command records them.

`allowed-dependency-accessor-stub` holds a client file from a real ship rehearsal's surface commit
byte for byte (checked with `git show <surface>:<path> | cmp - <fixture>`), its `DependencyValues`
accessor stubbed as `get { .init() }` and `set {}`. `allowed-dependency-accessor-wired` is the same
file with the accessor wired as `get { self[ShoppingListClient.self] }` and
`set { self[ShoppingListClient.self] = newValue }`, by the `sed` in the script.
`allowed-dependency-accessor-keys` wires 1 accessor to a key the base tree declares (`ItemClient`)
and 1 to a key another file of the same commit declares. `rejected-dependency-accessor-near-miss`
maps the client in a getter, returns a literal, stores `.init()` or a renamed setter parameter,
keys on an undeclared type, and wires a `self[…]` subscript outside `DependencyValues`. The same
capture command records them.

## Sprint slice manifests (`sprint slice`)

git 2.50.1 (Apple Git-155). The 3 `Package.swift` files a sprint rehearsal's surface (`b12ac55`) and
its slice 4 (`1e3285e`, which added the `ProfileClientLive` target and product) committed, from the
rehearsal checkout's `sprint/edit-your-profile` branch. `sprint-manifests/<side>/<path>.txt` is
`git show <rev>:<path>`; the `.txt` suffix keeps Swift tools off them.

```sh
R=<rehearsal checkout>
cd plugin/gate/Tests/Fixtures
for side in surface:b12ac55 slice:1e3285e; do
  name=${side%%:*}; rev=${side##*:}
  for p in Packages/AppFeature/Package.swift Packages/ProfileClient/Package.swift \
    Packages/ProfileFeature/Package.swift; do
    mkdir -p sprint-manifests/$name/$(dirname $p)
    git -C $R show $rev:$p > sprint-manifests/$name/$p.txt
  done
done
```

Between the sides, `ProfileClient` gains the `ProfileClientLive` target and product and 2 test
targets, `ProfileFeature` gains a test target and `AppFeature` gains a local package dependency and
its product: `sprint slice` refuses only `ProfileClient`'s change.
`build check-return` reads the same files as a plan surface and a task branch, and fails only
`ProfileClient`'s change with `build-return.target-outside-surface`.

## PlanState (`plan.json` written before spec pages)

The `plan.json` files the `swiftgate` on `main` at `9d91bcb` writes, before `plan.json` gained a
`source`: a design plan's seed from `plan claim --design`, and one that `plan set` then re-scoped.
They pin that every plan already in plan state decodes as a design plan. Captured in a throwaway
repository, never this checkout's shared plan state.

```sh
R=$(mktemp -d)/repo; S=5e0c7a1b-2d3f-4a6b-8c9d-0e1f2a3b4c5d
mkdir -p $R && cd $R && git init -q -b main && git commit -q --allow-empty -m init
swiftgate plan claim 2026-09-28-reading-list --session $S --design docs/reading/designs/reading-list.md
swiftgate plan claim 2026-09-28-saved-search --session $S --design docs/search/designs/saved-search.md --tier quick
swiftgate plan set 2026-09-28-saved-search --session $S --tier deep --resume 're-scoped to deep; next: research'
cp .git/swift-harness/plans/2026-09-28-reading-list/plan.json <fixtures>/PlanState/claim-seeded.json
cp .git/swift-harness/plans/2026-09-28-saved-search/plan.json <fixtures>/PlanState/plan-set-tier-and-resume.json
```

`confirm-user.json` and `confirm-spec-quotes.json` are the `plan.json` files `plan confirm` writes
with the `swiftgate` on `main` at `def1d1e`, before `delegate` was an approver. They pin that a
plan already confirmed by `user` or by `spec-quotes` decodes and re-encodes unchanged. With `FX`
this fixtures directory, in the same kind of throwaway repository:

```sh
swiftgate plan claim 2026-09-29-task-status --spec-page --session $S
swiftgate plan claim 2026-09-29-recipient-postcode --spec-page --session $S
P=$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans
cp $FX/spec-page/task-status.page.txt $P/2026-09-29-task-status/spec-page.md
cp $FX/spec-page/recipient-postcode.page.txt $P/2026-09-29-recipient-postcode/spec-page.md
swiftgate plan confirm 2026-09-29-task-status --by spec-quotes --spec $FX/spec-page/task-status.spec.txt --session $S
swiftgate plan confirm 2026-09-29-recipient-postcode --by user --spec $FX/spec-page/recipient-postcode.spec.txt --session $S
cp $P/2026-09-29-task-status/plan.json $FX/PlanState/confirm-spec-quotes.json
cp $P/2026-09-29-recipient-postcode/plan.json $FX/PlanState/confirm-user.json
```

## Spec pages (`spec-page check`)

`spec-page/<name>.page.txt` is a spec page a sprint session wrote from `spec-page/<name>.spec.txt`,
with Claude Code 2.1.282 on `opus`. The captures named both files `.md`; the `.txt` copies keep
the prose lint off tool output, and each page still names its spec as `<name>.spec.md`. The spec
files are generic features written for these captures, not the sprint rehearsals' prompts, so no
fixture quotes rehearsal prompt text. The rehearsal pages have the same shape; the tests derive a
wrapped goal like theirs from a captured page.

`spec-page/capture-prompt.txt` is the prompt head: the sprint skill's spec page step,
`skills/sprint/references/spec-page.md` and standards.md's module kinds, as they stood at capture,
followed by `=== SPECFILE`. In an empty directory holding `<name>.spec.md`:

| File | Capture |
|---|---|
| `task-status.page.txt`, `shipping-address.page.txt` | `sed "s#SPECFILE#<name>.spec.md#" capture-prompt.txt > prompt.txt && cat <name>.spec.md >> prompt.txt && claude -p --model opus --tools "" < prompt.txt > <name>.page.md` |
| `recipient-postcode.page.txt` | as above, with the prompt's last instruction line `Print ONLY the spec page's Markdown, nothing before or after it, no code fence. Use no tools.` replaced by `Write the page to ./page.md with the Write tool; you may check it with Bash (for example wc -w). Reply "done" when it is written.`, run as `claude -p --model opus --allowedTools "Write,Read,Bash(wc:*)" --permission-mode acceptEdits < prompt.txt`, then `page.md` copied |

What the pages show: every slice of `task-status` and `recipient-postcode` quotes its spec, so
both are `confirm: skippable`. `recipient-postcode` slice 2 quotes an acceptance line the spec
file wraps over 2 lines, joined onto 1. `shipping-address` marks the delivery note slice
`Spec: none` (its spec lists no acceptance line for it) and runs to 417 words, over the 400-word
limit: a real `too-long` page.

## Plan-lint on a spec-page plan (`plan-lint/`)

A design-free ship rehearsal's plan, copied byte for byte from its plan state after the decomposer
wrote it: the confirmed spec page and the ledger `plan-lint` judged. Its surface commit created a
client interface module and its `Live` module with no test target, and no task writes the
interface's `Tests/<Module>Tests/`. With `P` the rehearsal repo's
`$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans/<slug>` and `SC` its
recorded `surfaceCommit`:

| File | Capture |
|---|---|
| `shopping-list.page.txt` | `cp "$P/spec-page.md" shopping-list.page.txt` (sha256 matches the plan's `approval.pageSha`) |
| `shopping-list.ledger.json` | `cp "$P/ledger.json" shopping-list.ledger.json` |
| `describe-<Package>.json` (APIClient, LogClient, ShoppingListClient, AppFeature) | `R="$(cd "$(mktemp -d)" && pwd -P)"; git archive "$SC" \| tar -x -C "$R"; (cd "$R/Packages/<Package>" && swift package describe --type json) \| sed "s#$R#/REPO#g"` |

## Ledger page (`design-render --ledger`)

`ledger-page/design-plan-ledger.html` is the ledger page `swiftgate design-render --ledger` wrote for a
design plan before a plan could come from a spec page (harness `93ee095`, whose gate sources match
the change's base). `ledger-page/ledger.json` is its input ledger, written for the capture; the
design is `DesignSha/lf-proposed.md`. With `SG` the harness's `plugin/bin/swiftgate` and `FX` this
directory, in a temp directory:

```sh
git init -q -b main
mkdir -p docs/designs && cp "$FX/DesignSha/lf-proposed.md" docs/designs/queue.md
git add -A && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm design
"$SG" plan claim queue-plan --design docs/designs/queue.md --session 0b6f3c2e-7d1a-4e5b-9c8f-1a2b3c4d5e6f
P="$(git rev-parse --path-format=absolute --git-common-dir)/swift-harness/plans/queue-plan"
SHA=$(sed '2d' docs/designs/queue.md | git hash-object --stdin)   # the designSha: status line dropped
python3 -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['designSha']=sys.argv[2]; json.dump(d,open(p,'w'),indent=2)" "$P/plan.json" "$SHA"
cp "$FX/ledger-page/ledger.json" "$P/ledger.json"
"$SG" design-render --ledger queue-plan
cp .harness/design-render/queue-plan-ledger.html "$FX/ledger-page/design-plan-ledger.html"
```

It printed `designSha 72945ae95766ad279c53f464be8bffbe4e66f9d8`, the `DesignSha/hashes.txt` value
for `lf.stripped.md`.

## Context packs (`context-pack`)

`context-pack/design-decomposer.pack.txt` is the decomposer pack `swiftgate context-pack` wrote for
a design before it could read a spec page, so a test can hold a design's pack byte-identical. The
capture ran the harness at `bfb35b5`, exported whole (`git archive bfb35b5 plugin | tar -x`), in an
empty directory holding `Fixtures/design/valid.md` as `design.md`:

```sh
printf 'Sample: OrderQueueCore, OrderQueueFeature\n' > graph.txt
printf 'est_lines_max = 400\n' > bounds.txt
<export>/plugin/bin/swiftgate context-pack --role decomposer --design design.md \
  --module-graph graph.txt --task-sizing-bounds bounds.txt
cp .harness/context-pack/decomposer.md <fixtures>/context-pack/design-decomposer.pack.txt
```

## Transcripts

Claude Code transcripts and `--output-format json` envelopes from 2 throwaway sessions, for
transcript usage ingest. Captured with Claude Code 2.1.285 on model `claude-opus-5-5`, each from a
fresh empty directory made by `mktemp -d`, never from a real working session:

```sh
cd "$(mktemp -d)"
claude -p 'Reply with the single word ok.' --output-format json > plain.envelope.json
claude -p 'In one reply, first write the single word launching, then use the Agent tool exactly once to launch 1 subagent whose only task is to reply with the single word ok. Do nothing else. After it returns, reply with the single word ok.' --output-format json > subagent.envelope.json
```

Claude Code wrote each session's transcript to `~/.claude/projects/<cwd slug>/<session_id>.jsonl`,
and the subagent's to `~/.claude/projects/<cwd slug>/<session_id>/subagents/agent-<agentId>.jsonl`,
beside an `agent-<agentId>.meta.json` the fixtures leave out. The fixtures keep that layout under
`Transcripts/`, named by the envelope's `session_id`:

| File | Holds |
|---|---|
| `5812f394-….envelope.json` | the plain session's envelope, whole, pretty-printed with `jq .` |
| `5812f394-….jsonl` | its transcript: 1 user line, 1 assistant line |
| `a9349a9c-….envelope.json` | the subagent session's envelope, whole, pretty-printed with `jq .` |
| `a9349a9c-….jsonl` | its transcript: the first assistant message is 2 lines (text, then `tool_use`) with 1 `message.id` and the same usage on both |
| `a9349a9c-…/subagents/agent-a705c5b0d3c2b4f5b.jsonl` | the subagent's transcript, every line `isSidechain: true` |

This `jq` program filters each transcript, `jq -c "$F" <transcript> > <fixture>`:

```sh
F='select(.type=="assistant" or .type=="user") | {type, timestamp, isSidechain, message: (.message | {id, model, usage, content} | with_entries(select(.value != null)))}'
```

The filter drops every other line type (`attachment`, `queue-operation`, `last-prompt`, `cost-state`,
`atis-latch`) and every other key, including `cwd`, `gitBranch`, `sessionId`, `uuid` and `version`.
`message.content` stays: the prompts and replies are the throwaway text above, and a test needs text to
prove ingest doesn't store it. The fixtures keep the envelopes whole; they hold no path. After the copy,
`grep -rniE '/Users|/private|/tmp|caleb|@[a-z]+\.|swift-harness|home' Transcripts` matched nothing.

Usage deduplicated by `message.id` across the session transcript and its subagent transcripts equals
the envelope's `modelUsage` token counts. The 2 envelopes cost `total_cost_usd`
0.0478712 and 0.0525826. A third throwaway subagent session, not kept because its messages were 1
line each, cost 0.1193102 for 6 input, 124 output, 22096 cache-write and 31631 cache-read tokens.
The 3 envelopes solve, with no remainder, to $4 input, $5 5-minute cache write and $0.20 cache read
per 1M tokens, assuming output at 5 times input ($20).

### Tool calls (`39933227-…`)

A third throwaway session, for the tool summary ingest writes as `agent.tools`. It ran with Claude
Code 2.1.288 on model `claude-sonnet-5-5`, in a fresh git repository made by `mktemp -d` holding
`Sources/Greeting.swift` and `NOTES.md`, never in a real working session:

```sh
T=$(mktemp -d) && cd "$T" && git init -q -b main && mkdir Sources
printf 'struct Greeting {\n  let text = "hello"\n}\n' > Sources/Greeting.swift
printf '# Notes\n\nA throwaway repository.\n' > NOTES.md
git add -A && git commit -qm seed
claude -p 'Do exactly these steps, one tool call each, in this order, then reply with the single word done. 1. Use the Read tool on Sources/Greeting.swift. 2. Use the Edit tool to change "hello" to "hi" in Sources/Greeting.swift. 3. Use the Write tool to create Sources/Farewell.swift containing the single line: struct Farewell {}. 4. Use the Grep tool to search for the pattern struct in Sources. 5. Use the Bash tool to run: ls. 6. Use the Read tool on /etc/hosts. 7. Use the Agent tool exactly once to launch 1 subagent whose only task is to use the Read tool on NOTES.md and reply with its first line.' \
  --model sonnet --setting-sources project,local --permission-mode bypassPermissions \
  --output-format json > tools.json
```

This Claude Code build offers no `Grep` or `Glob` tool, so step 4 became a `ToolSearch` call that
found nothing, and the session said so. The main transcript's `tool_use` names, in order, are
`Read`, `Edit`, `Write`, `ToolSearch`, `Bash`, `Read` (`/etc/hosts`) and `Agent`; the subagent's is
1 `Read` of `NOTES.md`. `Bash ls` returned `(Bash completed with no output)`. `--output-format json`
printed an array of stream messages in this version, so the envelope is its last element,
`jq '.[-1]'`. It cost `total_cost_usd` 0.0763847.

The filter keeps `cwd`, which ingest needs to make paths repo-relative, and every content block,
`tool_use` and `tool_result` included. With `ROOT=$(cd "$T" && pwd -P)`:

```sh
F='select(.type=="assistant" or .type=="user") | {type, timestamp, isSidechain, cwd, message: (.message | {id, model, usage, content} | with_entries(select(.value != null)))}'
jq -c "$F" <session transcript> | sed "s#$ROOT#/REPO#g" > Transcripts/<session>.jsonl
jq -c "$F" <subagent transcript> | sed "s#$ROOT#/REPO#g" > Transcripts/<session>/subagents/agent-<agentId>.jsonl
jq '.[-1]' tools.json | sed "s#$ROOT#/REPO#g" > Transcripts/<session>.envelope.json
```

The `/etc/hosts` result is the stock macOS file. After the copy, the grep above matched nothing in
these 3 files.

Here a message's repeated lines carry the same usage.

### Streamed worker usage (`streamed/`)

`streamed/agent-ad10c26c66ae4d738.jsonl` is 1 worker transcript of the run view build
(`RunView/build-run-1/SOURCE`), the Workflow agent of task `counter-core-reset-and-decrement-floor`,
Claude Code 2.1.288 on `claude-sonnet-5-5`. Claude Code wrote it to
`~/.claude/projects/<cwd slug>/<session_id>/subagents/workflows/wf_4110cb4e-e8d/agent-ad10c26c66ae4d738.jsonl`.
Its first 2 messages are 2 lines each with 1 `message.id`: input and cache counts repeat byte for byte,
and `usage.output_tokens` reads 16, then 350, and 3, then 1077. Only the later line has a
`stop_reason`, and its `usage.iterations` total agrees with it. The filter drops
`message.content`, which held the scratch repository's paths, and keeps `stop_reason`:

```sh
F='select(.type=="assistant" or .type=="user") | {type, timestamp, isSidechain, message: (.message | {id, model, stop_reason, usage} | with_entries(select(.value != null)))}'
jq -c "$F" <worker transcript> > Transcripts/streamed/agent-ad10c26c66ae4d738.jsonl
```

After the copy, the grep above matched nothing in it.

### Worker paths in other worktrees (`worker-worktrees/`)

`worker-worktrees/agent-a5144c1382233c055.jsonl` and `agent-a1df530e0a9c131c0.jsonl` are 2 worker
transcripts of the `RunView/build-run-2` capture (see its `SOURCE`), the Workflow agents of tasks
`counter-ui-reset-button` and `counter-core-reset-and-decrement-floor`, Claude Code 2.1.288 on
`claude-sonnet-5-5`. Claude Code wrote them to
`~/.claude/projects/<cwd slug>/<session_id>/subagents/workflows/<workflow>/agent-<agentId>.jsonl`.
Every line's `cwd` is the scratch repository's main checkout, though the first worker's `Edit`
names a file in its own worktree beside it, `../app-<plan>-<task>`; the second's `Read` names the
main checkout's context pack. The filter keeps each line's type, time and `cwd`, and of its content
only `tool_use` blocks (`id`, `name` and the `file_path`, `path` or `notebook_path` input) and
`tool_result` blocks (`tool_use_id`), so no command, text or output. With `ROOT` the scratch
directory's `realpath`, the `$S` of that `SOURCE`:

```sh
F='select(.type=="assistant" or .type=="user") | {type, timestamp, isSidechain, cwd, message: {content: [.message.content[]? | objects | select(.type=="tool_use" or .type=="tool_result") | if .type=="tool_use" then {type, id, name, input: (.input | with_entries(select(.key=="file_path" or .key=="path" or .key=="notebook_path")))} else {type, tool_use_id} end]}}'
jq -c "$F" <worker transcript> | sed "s#$ROOT#/SCRATCH#g" > Transcripts/worker-worktrees/agent-<agentId>.jsonl
```

After the copy, both greps of `RunView/build-run-2` matched nothing in them.

## Events

`Events/judge.jsonl` is a judge audit log as the writer at `bbf0c62` wrote it, before the store
rotated or sealed anything, so a test can show that log still reads. It holds 24 lines: the
cascade-escalation and Jev-block routes of `JudgeEventsTests`, each run once through
`TestJudgeCheck.run` with the fake Jev and fake Claude reason judge those tests use, both given a
956-byte, 3-line reason. A test file added for the capture and removed after it ran this at
`bbf0c62`, from `plugin/gate`:

```sh
CAPTURE_JUDGE_LOG_ROOT=<scratch> swift test --filter CaptureJudgeLogTemp
cp <scratch>/.harness/events/judge.jsonl Tests/Fixtures/Events/judge.jsonl
```

Its body was:

```swift
let files = HarnessEventFiles(root: URL(filePath: out, directoryHint: .isDirectory))
let escalated = try await JudgeEventsTests.judged(
  judge: Steps.judge(Steps.jev, flagged: 0.5, rationale: nil),
  reasonJudge: Steps.reasonJudge(flagged: 0.95, rationale: reason, asked: Steps.Asked()))
let blocked = try await JudgeEventsTests.judged(
  judge: Steps.judge(Steps.jev, flagged: ["fails-if-broken": 0.95], otherwise: 0.1),
  reasonJudge: Steps.reasonJudge(flagged: 0.1, rationale: reason, asked: Steps.Asked()))
for event in escalated.log.events + blocked.log.events { try files.append(event) }
```

`grep -ciE '/Users|/private|/tmp|caleb|swift-harness' Events/judge.jsonl` printed 0.

`Events/gate.jsonl` is the gate stream of this repository's main checkout as its own push-tier
runs wrote it between the gate-run events merging and `5a0ab30`: 7 `gate.run` lines and their 70
`gate.step` lines. Every run is dirty with no tree hash, because the checkout held an untracked
file, and the 4th run is RED followed by a GREEN, so a test shows that runs with no tree hash
never pair into a flip. Copied at `5a0ab30`, from the repository root of the worktree:

```sh
/bin/cp -f <main checkout>/.harness/events/gate.jsonl plugin/gate/Tests/Fixtures/Events/gate.jsonl
```

`grep -ciE '/Users|/private|/tmp|caleb|swift-harness' Events/gate.jsonl` printed 0.

`Events/test-run.jsonl.lzfse` is the `test.result` stream of 1 real push-tier run on this
repository, LZFSE-compressed (122 KB, 1.37 MB of lines): 2,677 results, 2,673 passed and 4
skipped. `Events/test-run-gate.jsonl` is the same run's `gate.run` line, GREEN on a clean tree
with its tree hash. Captured at `4285f1e` (run `20261001T044910Z-f9efb34a`), from the repository
root of a fresh worktree that had run no gate before:

```sh
plugin/bin/swiftgate check --tier push
compression_tool -encode -a lzfse -i .harness/events/test.jsonl \
  -o plugin/gate/Tests/Fixtures/Events/test-run.jsonl.lzfse
grep '"gate.run"' .harness/events/gate.jsonl > plugin/gate/Tests/Fixtures/Events/test-run-gate.jsonl
```

`TestRollupStoreTests` builds its stores from copies of this run: each copy rewrites only every
event id, parent id and the run id so the copies are distinct runs; outcomes, durations, times and
the tree hash stay as captured. The timing of the flaky and slow-test section used 50 such
copies. The test ids `privateVarRoot`, `privateTmpPathIsFlagged`, `usersPathIsFlagged`,
`usersHitRaisesToBlocker` and `privateReference` match the path grep above. They are test names,
and no line holds a path.

`Events/hook.jsonl` is the hook stream the real `swiftgate hook` command wrote at `22168f8`, in a
scratch git repository whose `.swiftgate.toml` names 1 SwiftPM package `Pkg` with 1 library
target. This repository has no hook stream, because no Claude Code session runs the plugin's
hooks here. So the capture piped 1 session's payloads to the command by hand, from the scratch
repository's root, in this order:

1. `session-start`.
2. `pre-tool-use` for a Write of `Pkg/Package.resolved`, which `guard.package-resolved` denies.
3. `post-tool-use` for the same Write input: the bypass the hooks section counts.
4. `pre-tool-use` for Bash `xcodebuild test -scheme App`, which `guard.raw-xcodebuild` denies.
5. `pre-tool-use` and `post-tool-use` for a Write of `Pkg/Sources/Capture/B.swift`.
6. `stop`.

Step 2, as an example, and the copy:

```sh
printf '%s' '{"session_id":"<uuid>","cwd":"<scratch>","hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"<scratch>/Pkg/Package.resolved","content":"{}"}}' \
  | <worktree>/plugin/bin/swiftgate hook pre-tool-use
/bin/cp -f <scratch>/.harness/events/hook.jsonl plugin/gate/Tests/Fixtures/Events/hook.jsonl
```

`Events/cache.jsonl` is the cache stream a sibling worktree's own push-tier gate runs wrote at
its `51e7777` (2 manifest keys: 2 misses, 2 stores, 8 hits). Copied from the repository root
of this worktree:

```sh
/bin/cp -f <sibling worktree>/.harness/events/cache.jsonl plugin/gate/Tests/Fixtures/Events/cache.jsonl
```

`grep -ciE '/Users|/private|/tmp|caleb|swift-harness' Events/hook.jsonl Events/cache.jsonl`
printed 0 for each.

`Events/build.jsonl` is the build stream the real `swiftgate build halt` and `build resume` commands
wrote, built with their code as at `cb810e0`, in a scratch git repository whose `.swiftgate.toml`
names 1 package and leaves `[telemetry]` at its default. It holds 2 answered halts (`question`
answered `retry` after 3,053 ms, `gate-red` answered `continue` after 2,043 ms) and 1 halt of the
whole run (`budget`) that nothing answered, so a test can show an open halt listed with its age.
From the scratch repository's root, with `G=<worktree>/plugin/bin/swiftgate` and
`R=20261001T090000Z-0c0ffee1`:

```sh
$G build halt --run $R --task parse-config --reason question
/bin/sleep 3
$G build resume --run $R --task parse-config --answer retry
$G build halt --run $R --task render-report --reason gate-red
/bin/sleep 2
$G build resume --run $R --task render-report --answer continue
$G build halt --run $R --reason budget
/bin/cp -f .harness/events/build.jsonl <worktree>/plugin/gate/Tests/Fixtures/Events/build.jsonl
```

`grep -ciE '/Users|/private|/tmp|caleb|swift-harness' Events/build.jsonl` printed 0.

`Events/judge.jsonl` repeats its event ids across its 2 captured runs, because the fake judges
number their events from 1 in each run. A test that decodes the file reads all 24 lines; `events
summary`, which deduplicates by event id, keeps the first 12.

## Run view

`RunView/build-run-1/` is 1 real headless build, for the run view builder, reader and report.
`SOURCE` in that directory holds every command, the Claude Code version, the date and the build
run id, `20261004T045528Z-58d28c78`. In short: a `mktemp -d` copy of `examples/SampleApp`,
bootstrapped with `HOME` in scratch, with a `capture` preset (`design_tier = "none"`, Sonnet
workers, `task_proof = "final"`) and a 2-requirement spec (`spec.md`), ran
`/swift-harness:ship <spec> --preset capture` in `claude -p` with
`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0`. Ship wrote and confirmed the spec page (`plan.md`)
without asking, landed the surface commit, planned and built.

The decomposer split the 2 requirements into 3 tasks in 3 waves. Each file is a copy of the
state the run left, unedited:

| Task | Ledger status | What happened |
|---|---|---|
| `counter-core-reset-and-decrement-floor` | `done` | merged, merge gate GREEN |
| `counter-ui-reset-button` | `done` | its merge turned the push gate RED (a stale snapshot), `build merge --undo`, the fixer re-recorded the snapshot, the fix merge GREEN |
| `counter-ui-reset-button-snapshot` | `abandoned` | returned no commits, `build-return.no-commits` halted it; the resumed session answered `abandon`, an orchestrator-answered rehearsal, never the user |

The final `ready` gate, run `20261004T051601Z-46b2b09c`, was GREEN. The plan stays `building`
because the resumed session abandoned 1 task.

| File | Holds |
|---|---|
| `events/<stream>.jsonl` | the main store's `build` (1 halt, 1 resume), `gate` (17 `gate.run`, 88 `gate.step`), `test` (203), `hook` (70) and `cache` (175) streams, whole, preflight gates included |
| `events/imported/<store>/` | the 3 task worktree stores `worktree remove` imported, with their `store.json` |
| `ledger.json`, `ledger-events.jsonl` | the plan's ledger and its build run's `events.jsonl`: 7 transitions, 3 merges, 1 undo, 4 gates |
| `returns/<task>.json` | the 2 checked returns; the abandoned task's was refused, so none was written |
| `run.json`, `plan.json`, `plan.md`, `spec.md` | the build run record, the plan state, the spec page and the spec |

In the run, `events ingest` exited 2 after every task, first with `no session record` and, after
the resume wrote one, with `repeats an earlier message id with different usage` (see Transcripts).
The first failure came from the SessionStart hook running the shim's last good binary while the
plugin data cache rebuilt; that older binary refused a `plugin.json` with no `version`.

`events/usage.jsonl` holds 91 `agent.usage`: 68 main and 11 subagent orchestrator messages, and 4
per build worker. `events ingest`, from the commit that reads streamed messages, wrote it afterwards
in an `rsync` copy of the scratch app without `.harness/derived-data`, from the transcripts Claude
Code left. With `SG=<harness>/plugin/bin/swiftgate`,
`SES=306d86af-8556-4a2c-8300-5029ecae68b2`, `R=20261004T045528Z-58d28c78` and
`W=~/.claude/projects/<cwd slug>/$SES/subagents/workflows`, the same flags the run used:

```sh
for p in counter-core-reset-and-decrement-floor:wf_4110cb4e-e8d \
  counter-ui-reset-button:wf_04439a44-cc1 counter-ui-reset-button-snapshot:wf_45713b8a-4f4; do
  "$SG" events ingest --session $SES --workflow-transcripts $W/${p#*:} --role build-worker \
    --task ${p%%:*} --build-run $R
done
"$SG" events ingest --session $SES --role orchestrator --build-run $R
cp .harness/events/usage.jsonl <fixtures>/RunView/build-run-1/events/usage.jsonl
```

Each exited 0: 83 new, then 4, 4 and 0. The other streams and `store.json` stayed byte-identical.
No command records spans, `prove.result` or `agent.tools` yet; a later capture repeats this
run once one does.

The sources held no machine path, so no `sed` ran. Ledger worktrees are relative
(`../app-<plan>-<task>`). `grep -rniE '/Users|/private|/var/folders|/tmp|caleb|@[a-z]+\.|swift-harness|home' RunView`
and `grep -rniE 'sk-ant|api[_-]?key|ANTHROPIC|bearer|password|secret|token=' RunView` matched
nothing. `store.json` holds each store's random hashing salt, as written.

`RunView/span-sequence/span.jsonl` is the span stream a real `events span` sequence wrote, for the
span decoder and the run view builder. It holds a `plan` span around a `worker` span, each ended
once. Between them, `events span` refused 1 second end, 1 orphan end and 1 unknown phase, and wrote
nothing for any of them. Captured at the commit that records spans, from `plugin/gate` after `swift build`:

```sh
SG=$PWD/.build/debug/swiftgate T=$(mktemp -d) && cd $T && export LLVM_PROFILE_FILE=$T/%p.profraw
git init -q -b main
printf 'schema = 1\nxcode = "26.2"\napp_scheme = "Probe"\npackages = ["Probe"]\n\n[simulator]\ndevice = "iPhone 17"\nos = "26.2"\n' > .swiftgate.toml
git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m base
RUN=20261004T020000Z-5a1e0c0d
P=$($SG events span start --phase plan --build-run $RUN --role orchestrator)
W=$($SG events span start --phase worker --build-run $RUN --task counter-reset --role build-worker --parent $P)
sleep 1
$SG events span end $W --outcome ok                    # exit 0, "after 1065 ms"
$SG events span end $W --outcome ok                    # exit 1, "already ended; nothing recorded"
$SG events span end ffffffffffffffff --outcome ok      # exit 1, "no span ... was started"
$SG events span start --phase warmup --build-run $RUN  # exit 2, names the 11 phases
$SG events span end $P --outcome red                   # exit 0, "after 1367 ms"
cp .harness/events/span.jsonl <fixtures>/RunView/span-sequence/span.jsonl
```

The file holds the 4 lines written, unedited. `grep -ciE '/Users|/private|/var/folders|/tmp|caleb|swift-harness' RunView/span-sequence/span.jsonl`
printed 0.

## GateRun

`GateRun/report.json` is the `report.json` of a real push-tier run on the sample app, so a test can
record it and show which of its fields reach the `gate.run` event and which never do. Captured at
`b82667c` with Xcode 26.2 (Swift 6.2.3), from the repository root:

```sh
cd examples/SampleApp
../../plugin/bin/swiftgate check --tier push --base HEAD
cp .harness/runs/<run id>/report.json ../../plugin/gate/Tests/Fixtures/GateRun/report.json
```

The run was GREEN in 65.9s: T0 and T1 (31 tests passed), no simulator target selected with
`--base HEAD`, and 7 findings across 7 rules naming the files `.`, `.swiftgate.toml` and `docs`.
`grep -ciE '/Users|/private|/tmp|caleb|swift-harness' GateRun/report.json` printed 0.

## Xcode

1 `project.pbxproj` per inclusion kind, and the tool output read from it, captured from public
repositories pinned at a commit. Xcode 26.2 (17C48), XcodeGen 2.45.3 (Homebrew), Tuist 4.210.0
(the script installs it into its scratch directory with mise 2025.12.7, since this machine has no
Tuist), git 2.50.1. The script needs network access. From the repository root:

```sh
plugin/gate/Tests/Fixtures/Xcode/capture.sh
```

Each case has a `SOURCE` (URL, commit, commit date, license, GitHub languages, capture date, clone
command), the `git ls-files` of the clone (or of the project directory, for the 2 tool
repositories), and `tree/<tracked path>`: tracked files copied byte for byte. Swift manifests carry
a `.txt` suffix. Each command's output is in `<name>.stdout`, `<name>.stderr` and `<name>.status`,
with the clone root as `/REPO` and the temp dir as `/TMP`.

| Case | Repository | Inclusion | Captured output |
|---|---|---|---|
| `Xcode/synchronized/` | `Shopify/mobile-buy-sdk-ios` (MIT; Swift, Objective-C, Ruby), the first `gh search code PBXFileSystemSynchronizedRootGroup --filename project.pbxproj` result with a second language | 2 `PBXFileSystemSynchronizedRootGroup`s with 4 `PBXFileSystemSynchronizedBuildFileExceptionSet`s, beside a `Package.swift` | `xcodebuild-list` (`xcodebuild -list -json -project Buy.xcodeproj`) |
| `Xcode/explicit/` | `touchlab/KaMPKit` (Apache-2.0; Kotlin, Swift) | explicit file references, build files and Sources phases | `xcodebuild-list`; `plutil-lint-valid` (`plutil -lint` on the tracked file); `plutil-lint-damaged` and `xcodebuild-list-damaged` on `damaged/KaMPKitiOS.xcodeproj/project.pbxproj`, the first half of the tracked file's bytes (`head -c`) |
| `Xcode/xcodegen/` | `yonaskolb/XcodeGen` at tag `2.45.3` (MIT), its `Tests/Fixtures/SPM` | `project.yml`, generated project tracked | `xcodegen-version` (`xcodegen --version`); `xcodegen-generate` (`xcodegen generate` in the project directory), its project in `generated/`, and `git-status-after-generate.txt`; `not-installed` (`env PATH=/usr/bin:/bin xcodegen generate`) |
| `Xcode/tuist/` | `tuist/tuist` at tag `4.210.0` (MIT outside `server/`, `kura/`, `atlas/`), its `examples/xcode/generated_app_with_framework_and_tests` | `Project.swift`, generated project ignored by its `.gitignore` | `tuist-version` (`tuist version`); `tuist-generate` (`tuist generate --no-open`), its project in `generated/`, and `git-status-after-generate.txt` (`--ignored`); `not-installed` (`env PATH=/usr/bin:/bin tuist generate --no-open`) |

Observed behavior the Xcode readers rely on:

- The XcodeGen and Tuist generated projects and the explicit project hold no
  `PBXFileSystemSynchronized*` object. The synchronized project lists no source file at all. Each
  root group (`Buy`, `BuyTests`) names its exception sets. Each set names 1 target and the files
  under the folder that target leaves out (`membershipExceptions`, here `Info.plist`) or exports
  (`publicHeaders`).
- `xcodegen generate` with the pinned version rewrites the tracked project byte for byte:
  `git-status-after-generate.txt` is empty and `generated/` equals `tree/`. It prints 3 progress
  lines and `Created project at <absolute .xcodeproj path>` on stdout, nothing on stderr, exit 0.
- XcodeGen names a local package's folder reference after the directory it points at
  (`path: ../../..` becomes `name = XcodeGen`). Generating in a clone under another directory name
  changes the project, so a scratch tree used to generate must keep the repository directory's
  name.
- `tuist generate` writes `App.xcodeproj` and `App.xcworkspace`, both ignored, so
  `git status --porcelain` stays empty; its stdout ends `✔ Success` and `Project generated.` and
  carries a `Total time taken:` line that changes run to run.
- A missing generator run through `env` exits 127 with `env: <tool>: No such file or directory` on
  stderr and nothing on stdout.
- `plutil -lint` prints `<path>: OK` on stdout and exits 0 for a valid project. For the damaged file
  it exits 1 with `<path>: (Unexpected character / at line 1)` on stderr: plutil reports the
  failure at the comment header, not where the file ends.
- `xcodebuild -list -json` prints `project.{configurations,name,schemes,targets}`. For the damaged
  project it exits 74 with empty stdout, and stderr names it unreadable with a parse error (see
  `xcodebuild-list-damaged.stderr`). It also writes a result bundle into the user temp dir whatever
  `TMPDIR` says; the capture deletes the bundle it names.

## Discover

`Discover/<owner>-<repo>/` holds 1 public repository at a pinned commit, as `swiftgate discover` sees it
(design §5.1). `ls-files.txt` is its `git ls-files` listing. `tree/` holds the bytes of each signal file at its
tracked path, and symlinks stay symlinks. `SOURCE` names the URL, commit, commit date and capture date. When
`ls-files.txt` lists a path that `tree/` lacks, the path isn't a signal file and discover reads its name only
(lockfiles, `bin/*`, sources). Never edit a file after capture.

Each repository carries an MIT or Apache-2.0 license and holds more than 1 language. Captured 2026-10-03.

| Directory | Signal row | Commit |
|---|---|---|
| `Alamofire-Alamofire` | SwiftPM and an explicit Xcode project (Swift, Ruby) | `bda9ed57d72988a3a2ada33d824583541f86eac6` |
| `yonaskolb-XcodeGen` | XcodeGen `project.yml`, with a tracked generated project (Swift, Objective-C, C) | `366592bc5be446b427fc8e2a21520344460f96ab` |
| `square-workflow-swift` | Tuist `Project.swift` and `Workspace.swift` beside a root `Package.swift` (Swift, Python) | `03786ed826b594fc4e8b22c5ce91e042ea05e683` |
| `Shopify-mobile-buy-sdk-ios` | synchronized folders: the first `project.pbxproj` result of `gh search code PBXFileSystemSynchronizedRootGroup` (Swift, Ruby) | `350c914d8beea856026807cbd3effc73aaf8b7cd` |
| `touchlab-KaMPKit` | Gradle and Xcode together (Kotlin, Swift) | `4af02006be4be589e6848f097a92d97539300821` |
| `tauri-apps-tauri` | Cargo and node workspaces (Rust, TypeScript) | `30da1fd6e17de6107ecc850c95dfb16b5729f2dd` |
| `pola-rs-polars` | Cargo and Python (Rust, Python) | `9ee0dc5b818afbae7ddba308eddcf3174f6f5843` |
| `pocketbase-pocketbase` | Go and node (Go, JavaScript) | `5cec579da984436a258602a46a96302fbd31f77c` |
| `jhipster-jhipster-sample-app` | Maven and node (Java, TypeScript) | `6b000b5d23a36c45e01472471b84a44fa2464044` |
| `mitmproxy-mitmproxy` | Python and node (Python, TypeScript) | `3368a0a06ae6195aad817a1ece1aaeb6fe0353a1` |
| `hotwired-turbo-rails` | Ruby and node (Ruby, JavaScript) | `37530c08780fa6f6dbb56a633de4b81169bdd174` |
| `ggml-org-llama.cpp` | CMake, Python and SwiftPM (C++, Python, Swift) | `11fe02151f79c41d0d4af7da708755d73b9c0da6` |
| `phoenixframework-phoenix` | Elixir and node (Elixir, JavaScript) | `2ca60ffe811c0e585835cfc309b645c3a4190df1` |

Capture, per row, with `O=plugin/gate/Tests/Fixtures/Discover/<owner>-<repo>`, `R="$TMPDIR/<owner>-<repo>"` and
`signal` the filter below. `reset` fills the index from trees alone, so `ls-files` lists the commit without
fetching any blob; the pathspec `checkout` then fetches only the signal files' blobs:

```sh
git clone --depth 1 --filter=blob:none --no-checkout https://github.com/<owner>/<repo>.git "$R"
git -C "$R" fetch --depth 1 origin <commit> && git -C "$R" reset -q <commit>
git -C "$R" ls-files -z | tr '\0' '\n' > "$O/ls-files.txt"
git -C "$R" ls-files -z | tr '\0' '\n' | signal | tr '\n' '\0' \
  | git -C "$R" checkout -q <commit> --pathspec-from-file=- --pathspec-file-nul
mkdir -p "$O/tree"
git -C "$R" ls-files -z | tr '\0' '\n' | signal | tr '\n' '\0' \
  | (cd "$R" && xargs -0 tar -cf -) | (cd "$O/tree" && tar -xf -)
```

Then `rm -rf "$R"`, except for the 2 rows below.

`signal` is `grep -E` with this pattern, which matches the §5.1 signal files: build files, workspace files,
`.xcscheme` files, `project.pbxproj`, lint configs, `Makefile`, `justfile`, CI workflow files and tool pins:

```text
(^|/)(Package(@swift-[0-9.]+)?\.swift|project\.ya?ml|Project\.swift|Workspace\.swift|Tuist\.swift|Tuist/Config\.swift|Tuist/Package\.swift|Cargo\.toml|go\.mod|go\.work|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|gradle\.properties|gradle-wrapper\.properties|libs\.versions\.toml|pom\.xml|maven-wrapper\.properties|package\.json|pnpm-workspace\.yaml|lerna\.json|nx\.json|turbo\.json|rush\.json|\.yarnrc\.yml|pyproject\.toml|setup\.cfg|tox\.ini|pytest\.ini|Gemfile|\.rspec|Rakefile|mix\.exs|CMakeLists\.txt|CMakePresets\.json|(GNU)?[Mm]akefile|[Jj]ustfile|\.gitlab-ci\.yml|[^/]+\.xcscheme|contents\.xcworkspacedata|project\.pbxproj|\.swiftlint\.ya?ml|\.swiftformat|\.swift-format|\.eslintrc(\.[a-z]+)?|eslint\.config\.[cm]?[jt]s|biome\.jsonc?|\.prettierrc(\.[a-z]+)?|ruff\.toml|\.ruff\.toml|\.flake8|\.pylintrc|mypy\.ini|\.rubocop\.yml|\.golangci\.(ya?ml|toml)|\.?clippy\.toml|\.?rustfmt\.toml|detekt(-config)?\.ya?ml|\.editorconfig|\.credo\.exs|\.formatter\.exs|\.clang-format|\.clang-tidy|\.tool-versions|\.?mise\.toml|\.nvmrc|\.node-version|\.python-version|\.ruby-version|rust-toolchain(\.toml)?|\.swift-version|\.xcode-version|\.java-version|\.sdkmanrc|\.go-version|Mintfile)$|(^|/)\.github/workflows/[^/]+\.ya?ml$
```

`usememos-memos` (Go, TypeScript; MIT) came later, on 2026-10-04, from the first brownfield trial's pinned clone
rather than from GitHub. It holds `web/pnpm-workspace.yaml` with pnpm settings and no `packages:` key, and a
backend workflow whose test step sets `DRIVER` in its own `env:`. Capture it with the commands above, with `R`
a scratch directory, the commit `0d989707f82c33f74bb852edd8965ec88fcf041b` and, in place of the first 2 lines,
a clone of that local checkout, which already holds the commit:

```sh
git clone -q --no-checkout <path to the trial's memos clone> "$R"
git -C "$R" reset -q 0d989707f82c33f74bb852edd8965ec88fcf041b
```

The 2 `after-build/` directories are the negative case: build output on disk that git ignores.
After the capture above, in the same clone and before deleting it, `git -C "$R" checkout -q -f <commit>`, then the repository's own build
or install, then `git -C "$R" ls-files -z | tr '\0' '\n' > "$O/after-build/ls-files.txt"` and
`git -C "$R" status --porcelain --ignored > "$O/after-build/status-ignored.txt"`:

| Directory | Build | Ignored output |
|---|---|---|
| `Alamofire-Alamofire/after-build` | `swift build` (Swift 6.2) | `.build/` |
| `phoenixframework-phoenix/after-build` | `npm ci` (node 22.23.3, npm 10.9.9) | `node_modules/` |

Both `after-build/ls-files.txt` files are byte-identical to their row's `ls-files.txt`: the build adds nothing
tracked.

## Neutral diffs

`NeutralDiffs/<language>/<case>.diff` is a single file's diff from a real commit in a public
repository under Apache-2.0, MIT or BSD. The `<case>.SOURCE` beside it records the repository,
the commit sha, the file path and the exact command. Each capture runs in a full clone of the
repository's default branch (`git clone --single-branch https://github.com/<repo>.git`) with no
diff settings in the git config:

```sh
git show --format= <sha> -- <path> > NeutralDiffs/<language>/<case>.diff
```

The capture searched each clone with `git log -G'<token regex>' --format=%H -- '<glob>'` and kept
small single-file diffs whose added lines carry the token. The case name says what the added lines
hold:

- An unsafe shortcut, lint suppression, or skipped or focused test: `try-bang`, `as-bang`,
  `fatal-error`, `unchecked-sendable`, `nonisolated-unsafe`, `bang-bang`, `as-any`, `ts-ignore`,
  `ts-expect-error`, `swiftlint-disable`, `suppress`, `suppress-warnings`, `eslint-disable`,
  `noqa-type-ignore`, `nolint`, `clippy-allow`, `rubocop-disable`, `disabled-test`,
  `xctskip-test`, `ignored-test`, `skipped-test`, `focused-test`.
- `test-no-assertion`: a new test whose added lines hold no assertion. The Go, Python, Ruby and
  Swift cases run code and check nothing; the TypeScript and Kotlin cases are compile-only API
  checks; the Rust case calls a helper that may assert, so the judge cascade decides it.
- `test-with-assertion`: a new test with its own assertions.
- `fp-*`: false positives. The token sits only in a comment or a string literal on added lines:
  `swift/fp-comment-try-bang` (its context holds a real, unchanged `try!` line),
  `swift/fp-comment-fatal-error`, `swift/fp-string-as-bang` (SwiftLint's rule examples),
  `typescript/fp-string-as-any` (typescript-eslint's rule test code) and
  `typescript/fp-comment-as-any` (commented-out code).

Some cases carry several tokens, as their commits do. `swift/try-bang` also adds a `fatalError`;
`typescript/ts-ignore` and `typescript/ts-expect-error` also add an `eslint-disable-next-line`;
`python/noqa-type-ignore` adds both. `python/skipped-test` is a `skipif` on a test that asserts,
and `swift/nonisolated-unsafe` is a new test file that asserts.

No small Java commit adding an assertion-free test turned up in `square/okhttp` or
`square/javapoet`, so Java has no `test-no-assertion` case. Kotlin has no string-literal false
positive case.

## Area runs

`AreaRuns/<ecosystem>/<case>/` holds 1 real run of a repository's own test runner or linter, as the
brownfield area runner sees it. Each case directory has these files:

- `command`: the exact string run through `/bin/sh -c` from the directory named below.
- `exit`: the status `/bin/sh` reported. Above 128, the process died of signal `exit - 128`.
- `stdout` and `stderr`, and `junit.xml` when the runner wrote one.
- `change.diff`: `git diff` of the edit in the scratch clone before the run, so a reader can map
  findings to added lines.

The cases `test-pass`, `test-fail` and `test-crash` run 1 passing, 1 failing and 1 crashing test;
`lint` runs the linter on 1 changed file with findings. The capture edited each file with the
command listed, ran the case, then reverted the file with `git checkout`.

Captured 2026-10-03 on macOS 26 (arm64) under heavy load, so durations in the output are not
representative. Tools went into scratch only, through `mise` with `MISE_DATA_DIR` under `$TMPDIR`
(mise 2025.12.7) or the repository's wrapper. Every clone was `git clone --depth 1 <url>` into
`$SCRATCH/repos`:

| Ecosystem | Repository @ commit | Ran from | Tools |
|---|---|---|---|
| `python` | `ggml-org/llama.cpp` @ `11fe02151f79c41d0d4af7da708755d73b9c0da6` | repository root | Python 3.13.11 (uv venv), pytest 9.1.1, flake8 7.4.1 (pycodestyle 2.15.0, pyflakes 4.0.2) |
| `node` tests | `vercel/turborepo` @ `66dbdb377cae04107ef03e155ad1bd55c5a479ac` | `packages/turbo-utils` | node 24.21.0, pnpm 12.0.0, jest 30.3.0, jest-junit 16.0.0 |
| `node` lint | `tauri-apps/tauri` @ `30da1fd6e17de6107ecc850c95dfb16b5729f2dd` | `packages/api` | node 24.21.0, pnpm 12.4.2, ESLint 10.0.2 |
| `go` | `pocketbase/pocketbase` @ `5cec579da984436a258602a46a96302fbd31f77c` | repository root | go 1.27.1 (`GOTOOLCHAIN=local`), golangci-lint 2.14.0 |
| `cargo` | `astral-sh/ruff` @ `1df6db3e463ffa1b587dcf47f25360d40389b0f7` | repository root | rustup with the repository's `rust-toolchain.toml`: cargo 1.99.0, clippy 0.1.99 |
| `gradle` | `square/okhttp` @ `75d8f91cfe2495b79d07b1dabe05789caa429ac2` | repository root | Temurin JDK 21.0.12, `./gradlew` (Gradle 9.6.1), Spotless 8.10.3 with ktlint 1.8.0 |
| `maven` | `jhipster/jhipster-sample-app` @ `6b000b5d23a36c45e01472471b84a44fa2464044` | repository root | Temurin JDK 21.0.12, `./mvnw` (Maven 3.9.16), Surefire 3.5.6, maven-checkstyle-plugin 3.6.0 with Checkstyle 14.1.0 and nohttp-checkstyle 0.0.11 |
| `ruby` tests | `rubocop/rubocop` @ `ec1080049ab773c5b5cca42cf963349be293c0a7` | repository root | Ruby 4.0.7, Bundler 4.0.20, rspec-core 3.13.6 |
| `ruby` lint | `mastodon/mastodon` @ `79f21a20736ba85a0b59c976cddbf88e880b28c9` | repository root | Ruby 4.0.7, Bundler 4.0.20, RuboCop 1.91.0 |
| `swift` tests | `yonaskolb/XcodeGen` @ `366592bc5be446b427fc8e2a21520344460f96ab` | repository root | Apple Swift 6.2 (swiftlang-6.2.3.3.20) |
| `swift` lint | `element-hq/element-x-ios` @ `9f141585a2eb641c38e18c21d7030e4b95a53a19` | repository root | SwiftLint 0.65.1 (the repository pins none) |

The Ruby tests come from `rubocop/rubocop`, which is not in the plan's fixture list: every spec in
`mastodon/mastodon` and `discourse/discourse` loads Rails with Postgres and Redis. Neither Ruby
repository bundles `rspec_junit_formatter`, so `ruby` has no `junit.xml`. Cargo and Go write no JUnit;
Go's `-json` stream is the structured output. No tool was missing.

### Scratch environment and helpers

```sh
export SCRATCH=${TMPDIR%/}/area-outputs SCRATCH_P=$(cd "$SCRATCH" && pwd -P)
export MISE_DATA_DIR=$SCRATCH/mise MISE_CACHE_DIR=$SCRATCH/mise-cache MISE_YES=1
export RUSTUP_HOME=$SCRATCH/rustup CARGO_HOME=$SCRATCH/cargo UV_CACHE_DIR=$SCRATCH/uv-cache
export GOPATH=$SCRATCH/gopath GOMODCACHE=$SCRATCH/gopath/pkg/mod GOCACHE=$SCRATCH/gocache
export npm_config_cache=$SCRATCH/npm-cache GRADLE_USER_HOME=$SCRATCH/gradle
export MAVEN_OPTS=-Dmaven.repo.local=$SCRATCH/m2 MAVEN_USER_HOME=$SCRATCH/m2home
export GEM_HOME=$SCRATCH/gems XDG_CACHE_HOME=$SCRATCH/xdg-cache
export F=<worktree>/plugin/gate/Tests/Fixtures/AreaRuns CAP=$SCRATCH/cap.sh
mise install go@1.27 golangci-lint@latest java@temurin-21 node@24 ruby@4.0.7 rust@1.90 swiftlint@latest
mise exec node@24 -- npm i -g --prefix $SCRATCH/pnpm12 pnpm@12.0.0    # and pnpm@12.4.2 into $SCRATCH/pnpm124
```

`$SCRATCH/cap.sh`:

```sh
#!/bin/sh
# cap.sh <fixture-dir> <command> [junit-file]
d="$1"; c="$2"; j="$3"; mkdir -p "$d"
printf '%s\n' "$c" > "$d/command"
/bin/sh -c "$c" > "$d/stdout" 2> "$d/stderr"
echo $? > "$d/exit"
if [ -n "$j" ] && [ -f "$j" ]; then mv "$j" "$d/junit.xml"; fi
"$(dirname "$0")/scrub.sh" "$d"/stdout "$d"/stderr $( [ -f "$d/junit.xml" ] && echo "$d/junit.xml" )
```

`$SCRATCH/scrub.sh` replaces machine paths, the host name and the user name. After the last capture
it ran once more over every `stdout`, `stderr` and `junit.xml` (from inside a clone; it is
idempotent), because the user-name and `$TMPDIR` rules came last. This first version wrote `<repo>`
into `junit.xml` too, which left those reports ill-formed XML; the reports were recaptured with the
version under "Recaptured reports" below:

```sh
#!/bin/sh
R=$(git rev-parse --show-toplevel); R_L=${R#/private}; T=${TMPDIR%/}
for f in "$@"; do
  sed -i '' -e "s#${R}#<repo>#g" -e "s#${R_L}#<repo>#g" \
    -e "s#${SCRATCH_P}#<scratch>#g" -e "s#${SCRATCH}#<scratch>#g" \
    -e "s#/private${T}#<tmp>#g" -e "s#${T}#<tmp>#g" -e "s#${HOME}#<home>#g" \
    -e "s#$(hostname)#<host>#g" -e "s#\"$(id -un)\"#\"<user>\"#g" "$f"
done
```

So `<repo>` is the clone's root (not the directory the command ran in), `<scratch>` the scratch
directory, `<home>` the home directory, `<tmp>` `$TMPDIR`, and `<host>` and `<user>` the machine's
names. `grep -rIl -i -e caleb -e /Users/ -e /private/ -e /var/folders AreaRuns` prints nothing.

### Recaptured reports

Every case with a `junit.xml` from the Gradle, Maven, node and Python captures above
(`gradle/test-{pass,fail,crash}`, `maven/test-{pass,fail}`, `node/test-{pass,fail}`,
`python/test-{pass,fail}`) was captured again on 2026-10-04 with the same commands, clones at the
same commits, and the same tool versions, so each report is well-formed XML. Each case's
`stdout`, `stderr` and `exit` come from the same run as its report. The clones were fetched at their
commits (`git init; git fetch --depth 1 origin <sha>; git checkout FETCH_HEAD`), and tools went into
a new scratch directory the same way. The scrub now escapes each placeholder inside a report, so
`<repo>` reads back from the XML as text:

```sh
#!/bin/sh
# Placeholders are <repo> in text, and &lt;repo&gt; inside an XML report so it stays well-formed.
R=$(git rev-parse --show-toplevel); R_L=${R#/private}; T=${TMPDIR%/}; SP=$(cd "$SCRATCH" && pwd -P)
for f in "$@"; do
  case "$f" in *.xml) o='\&lt;'; c='\&gt;';; *) o='<'; c='>';; esac
  sed -i '' -e "s#${R}#${o}repo${c}#g" -e "s#${R_L}#${o}repo${c}#g" \
    -e "s#${SP}#${o}scratch${c}#g" -e "s#${SCRATCH}#${o}scratch${c}#g" \
    -e "s#/private${T}#${o}tmp${c}#g" -e "s#${T}#${o}tmp${c}#g" -e "s#${HOME}#${o}home${c}#g" \
    -e "s#$(hostname)#${o}host${c}#g" -e "s#\"$(id -un)\"#\"${o}user${c}\"#g" "$f"
done
```

`cap.sh` also removes a `junit.xml` left in the case directory before it moves the new one in. The
Gradle and Maven capture commands now run `rm -rf okhttp-sse/build/test-results` or
`rm -rf target/surefire-reports` before each test run, as the original note says, and the Gradle
`test-pass` run came after a warm-up so its output holds no distribution download. The okhttp
`test-crash` report now holds 2 cases, not 12: `retryInvalidFormatIgnored()` passed and
`multilineCrLf()` is marked skipped, while `exits()` is absent. JUnit ran the class's methods in
another order, and the executor's exit ended the run there.

### Captures

`python` (llama.cpp; `uv venv $SCRATCH/venv-py && uv pip install -e gguf-py pytest flake8`):

```sh
T=gguf-py/tests/test_metadata.py
$CAP $F/python/test-pass "pytest $T::TestMetadataMethod::test_id_to_title --junitxml=.area-junit.xml" .area-junit.xml
sed -i '' 's/"Meta Llama 3 8B")/"Meta Llama 3 70B")/' $T
$CAP $F/python/test-fail "pytest $T::TestMetadataMethod::test_id_to_title --junitxml=.area-junit.xml" .area-junit.xml
printf '\n\nclass TestAbort(unittest.TestCase):\n\n    def test_abort(self):\n        os.abort()\n' >> $T
$CAP $F/python/test-crash "pytest $T --junitxml=.area-junit.xml" .area-junit.xml
L=gguf-py/gguf/utility.py
sed -i '' '1,/^import /s/^\(import .*\)$/\1\nimport tempfile/' $L; printf 'def _unused():\n    value = 1 \n' >> $L
$CAP $F/python/lint "flake8 $L"
```

`node` tests (turborepo; `pnpm install --store-dir $SCRATCH/pnpm-store --filter "@turbo/utils..."`,
then `pnpm add -D jest-junit@16.0.0 --filter @turbo/utils`, every command under
`mise exec node@24`):

```sh
cd packages/turbo-utils; T=__tests__/convert-case.test.ts
C="JEST_JUNIT_OUTPUT_FILE=.area-junit.xml pnpm exec jest $T --reporters=default --reporters=jest-junit"
$CAP $F/node/test-pass "$C" .area-junit.xml
sed -i '' 's/{ input: "hello_world", expected: "helloWorld", to: "camel" }/{ input: "hello_world", expected: "hello_world", to: "camel" }/' $T
$CAP $F/node/test-fail "$C" .area-junit.xml
printf '\ndescribe("abort", () => {\n  it("aborts the process", () => {\n    process.abort();\n  });\n});\n' >> $T
$CAP $F/node/test-crash "$C" .area-junit.xml
```

`node` lint (tauri; `pnpm install --store-dir $SCRATCH/pnpm-store --filter "@tauri-apps/api"`):

```sh
cd packages/api; L=src/dpi.ts
printf '\nfunction debugScale(factor: number): number {\n  const unused = factor * 2\n  console.log(factor)\n  return factor\n}\n' >> $L
$CAP $F/node/lint "pnpm exec eslint $L"
```

`go` (pocketbase; `go mod download`, under `mise exec go@1.27 golangci-lint@latest`):

```sh
T=tools/list/list_test.go
$CAP $F/go/test-pass "go test -json -run '^TestSubtractSliceString\$' ./tools/list"
sed -i '' 's/`\["1","3","7"\]`/`["1","3"]`/' $T
$CAP $F/go/test-fail "go test -json -run '^TestSubtractSliceString\$' ./tools/list"
printf 'package list_test\n\nimport (\n\t"os"\n\t"testing"\n)\n\nfunc TestExit(t *testing.T) {\n\tos.Exit(3)\n}\n' > tools/list/exit_test.go
$CAP $F/go/test-crash "go test -json -run '^(TestSubtractSliceString|TestExit)\$' ./tools/list"
L=tools/list/list.go
printf '\nfunc unusedHelper() int {\n\n\tx := 1\n\tx = 2\n\treturn x\n}\n' >> $L
$CAP $F/go/lint "golangci-lint run -c ./golangci.yml ./tools/list/..."
```

`cargo` (ruff; `PATH=$CARGO_HOME/bin:$PATH`, so rustup reads the repository's pin):

```sh
T=crates/ruff_text_size/tests/main.rs
$CAP $F/cargo/test-pass "cargo test -p ruff_text_size --test main -- --exact sum"
sed -i '' 's/assert_eq!(xs.iter().sum::<TextSize>(), size(3));/assert_eq!(xs.iter().sum::<TextSize>(), size(4));/' $T
$CAP $F/cargo/test-fail "cargo test -p ruff_text_size --test main -- --exact sum"
printf '\n#[test]\nfn aborts() {\n    std::process::abort();\n}\n' >> $T
$CAP $F/cargo/test-crash "cargo test -p ruff_text_size --test main"
L=crates/ruff_text_size/src/size.rs
printf '\npub fn is_empty_list(values: &Vec<u32>) -> bool {\n    values.len() == 0\n}\n' >> $L
$CAP $F/cargo/lint "cargo clippy -p ruff_text_size --locked"
```

`gradle` (okhttp, under `mise exec java@temurin-21`; `rm -rf okhttp-sse/build/test-results` before each
test run):

```sh
T=okhttp-sse/src/test/java/okhttp3/sse/internal/ServerSentEventIteratorTest.kt
J=okhttp-sse/build/test-results/test/TEST-okhttp3.sse.internal.ServerSentEventIteratorTest.xml
C="./gradlew :okhttp-sse:test --tests 'okhttp3.sse.internal.ServerSentEventIteratorTest.multiline'"
$CAP $F/gradle/test-pass "$C" $J
sed -i '' 's|Event(null, null, "YHOO\\n+2\\n10")|Event(null, null, "YHOO\\n+2\\n11")|' $T
$CAP $F/gradle/test-fail "$C" $J
perl -0pi -e 's/(class ServerSentEventIteratorTest \{\n)/$1  \@Test\n  fun exits() {\n    System.exit(3)\n  }\n\n/' $T
$CAP $F/gradle/test-crash "./gradlew :okhttp-sse:test --tests 'okhttp3.sse.internal.ServerSentEventIteratorTest'" $J
L=okhttp-sse/src/main/kotlin/okhttp3/sse/EventSources.kt
perl -0pi -e 's/(package okhttp3.sse\n\n)/$1import java.util.*\n/' $L; printf '\ninternal fun debugName(id:Int) : String = "source-"+id\n' >> $L
$CAP $F/gradle/lint "./gradlew :okhttp-sse:spotlessKotlinCheck"
```

`maven` (jhipster-sample-app, under `mise exec java@temurin-21`; `-P-webapp` skips the profile that
installs node; `rm -rf target/surefire-reports` before each test run):

```sh
T=src/test/java/io/github/jhipster/sample/security/SecurityUtilsUnitTest.java
J=target/surefire-reports/TEST-io.github.jhipster.sample.security.SecurityUtilsUnitTest.xml
C="./mvnw -ntp -P-webapp test -Dtest='SecurityUtilsUnitTest#testGetCurrentUserLogin'"
$CAP $F/maven/test-pass "$C" $J
sed -i '' 's/assertThat(login).contains("admin");/assertThat(login).contains("root");/' $T
$CAP $F/maven/test-fail "$C" $J
perl -0pi -e 's/(class SecurityUtilsUnitTest \{\n)/$1\n    \@Test\n    void exits() {\n        System.exit(3);\n    }\n/' $T
$CAP $F/maven/test-crash "./mvnw -ntp -P-webapp test -Dtest=SecurityUtilsUnitTest" $J
printf '\nSee http://example.com/docs for the old guide.\n' >> README.md
$CAP $F/maven/lint "./mvnw -ntp -P-webapp checkstyle:check"
```

`ruby` tests (rubocop; `BUNDLE_PATH=$SCRATCH/bundle-rubocop bundle install`, under `mise exec ruby@4.0.7`):

```sh
T=spec/rubocop/cop/style/redundant_return_spec.rb
$CAP $F/ruby/test-pass "bundle exec rspec $T:6"
perl -0pi -e 's/(    expect_correction\(<<~RUBY\)\n      def func\n        )something/${1}something_else/' $T
$CAP $F/ruby/test-fail "bundle exec rspec $T:6"
perl -0pi -e "s/(  let\(:cop_config\) \{ \{ 'AllowMultipleReturnValues' => false \} \}\n)/\$1\n  it 'aborts the process' do\n    Process.kill('ABRT', Process.pid)\n  end\n/" $T
$CAP $F/ruby/test-crash "bundle exec rspec $T:6:7"
```

`ruby` lint (mastodon; `BUNDLE_ONLY=development BUNDLE_PATH=$SCRATCH/bundle bundle install`, the
group that holds RuboCop and its plugins):

```sh
L=app/lib/hashtag_normalizer.rb
perl -0pi -e 's/(  private\n)/  def debug_label(str)\n    unused = str.length\n    return "tag: " + str\n  end\n\n$1/' $L
$CAP $F/ruby/lint "bundle exec rubocop $L"
```

`swift` tests (XcodeGen; `swift build --build-tests` first; `rm -f .area-junit-swift-testing.xml`
after each run):

```sh
T=Tests/XcodeGenCoreTests/ArrayExtensionsTests.swift
C="swift test --parallel --filter XcodeGenCoreTests.ArrayExtensionsTests/testSearchingForFirstIndex --xunit-output .area-junit.xml"
$CAP $F/swift/test-pass "$C" .area-junit.xml
sed -i '' 's/XCTAssertEqual(array.firstIndex(where: { $0 > 2 }), 2)/XCTAssertEqual(array.firstIndex(where: { $0 > 2 }), 3)/' $T
$CAP $F/swift/test-fail "$C" .area-junit.xml
perl -0pi -e 's/(class ArrayExtensionsTests: XCTestCase \{\n)/$1\n    func testAbort() {\n        abort()\n    }\n/' $T
$CAP $F/swift/test-crash "swift test --parallel --filter XcodeGenCoreTests.ArrayExtensionsTests --xunit-output .area-junit.xml" .area-junit.xml
```

`swift` lint (element-x-ios, under `mise exec swiftlint@latest`; the repository's `.swiftlint.yml`):

```sh
L=ElementX/Sources/Other/Extensions/Array.swift
printf '\nfunc firstLabel(_ values: [Any]) -> String {\n    let label = values.first as! String\n    return URL(string: label)!.absoluteString\n}\n' >> $L
$CAP $F/swift/lint "swiftlint lint --quiet $L"
```

### What each case shows

| Case | exit | JUnit (tests / failures) | Signature a reader relies on |
|---|---|---|---|
| `python/test-pass` | 0 | 1 / 0 | `1 passed` |
| `python/test-fail` | 1 | 1 / 1 | `FAILED gguf-py/tests/test_metadata.py::TestMetadataMethod::test_id_to_title` |
| `python/test-crash` | 134 (SIGABRT) | none written | stderr `Fatal Python error: Aborted`; 5 tests passed before it |
| `node/test-pass` | 0 | 4 / 0 | `Tests: 4 passed` (1 `it.each` over 4 rows) |
| `node/test-fail` | 1 | 4 / 1 | `Tests: 1 failed, 3 passed` |
| `node/test-crash` | 1 | none written | `pnpm exec` turns the signal into status 1; only stderr's native and JavaScript stack traces show the abort |
| `go/test-pass` | 0 | — | `-json` events, final `"Action":"pass"` |
| `go/test-fail` | 1 | — | `"Action":"fail"` for `TestSubtractSliceString` and its subtest `4_["1","3"]` |
| `go/test-crash` | 1 | — | `TestExit` has a `run` event and no `pass` or `fail`; the package `fail`s; `TestSubtractSliceString` never ran (files run in name order) |
| `cargo/test-pass` | 0 | — | `test sum ... ok` |
| `cargo/test-fail` | 101 | — | `test sum ... FAILED`, panic at `crates/ruff_text_size/tests/main.rs:17:5` |
| `cargo/test-crash` | 101 | — | stderr `process didn't exit successfully: ... (signal: 6, SIGABRT: process abort signal)`; stdout stops after `running 9 tests` |
| `gradle/test-pass` | 0 | 1 / 0 | `BUILD SUCCESSFUL` |
| `gradle/test-fail` | 1 | 1 / 1 | `ServerSentEventIteratorTest > multiline() FAILED` |
| `gradle/test-crash` | 1 | 2 / 0, 1 skipped | stderr `Process 'Gradle Test Executor 4' finished with non-zero exit value 3`; the JUnit file marks 1 case `<skipped/>` (`multilineCrLf()` in this run) and leaves `exits()` out, so JUnit alone reads as a pass |
| `maven/test-pass` | 0 | 1 / 0 | `Tests run: 1, Failures: 0` |
| `maven/test-fail` | 1 | 1 / 1 | `Tests run: 1, Failures: 1` |
| `maven/test-crash` | 1 | none written | `The forked VM terminated without properly saying goodbye. VM crash or System.exit called?` |
| `ruby/test-pass` | 0 | — | `1 example, 0 failures` |
| `ruby/test-fail` | 1 | — | `1 example, 1 failure`, `rspec ./spec/rubocop/cop/style/redundant_return_spec.rb:6` |
| `ruby/test-crash` | 134 (SIGABRT) | — | stderr `[BUG] Aborted` and Ruby's crash report (about 250 KB) |
| `swift/test-pass` | 0 | 1 / 0 | `--xunit-output` writes only with `--parallel`; without it no file appears |
| `swift/test-fail` | 1 | 1 / 1 | `ArrayExtensionsTests.swift:8: error: ... XCTAssertEqual failed` |
| `swift/test-crash` | 1 | 5 / 1 | stderr `error: Exited with unexpected signal code 6`; JUnit marks `testAbort` `<failure message="failure">` |

Lint findings, by path relative to `<repo>` and line, on the lines `change.diff` adds:

| Case | exit | Findings | Path form in the output |
|---|---|---|---|
| `python/lint` (flake8) | 1 | `gguf-py/gguf/utility.py` 8 F401, 342 E302, 343 F841, 343 W291 | repository-relative, `path:line:col: CODE message` |
| `node/lint` (ESLint stylish) | 1 | `packages/api/src/dpi.ts` 478 and 479 `@typescript-eslint/no-unused-vars`, 480 `no-console` | absolute (`<repo>/packages/api/src/dpi.ts`) heading, then `line:col  error  message  rule` |
| `go/lint` (golangci-lint) | 1 | `tools/list/list.go` 167 ineffassign, 165 unused | repository-relative, `path:line:col: message (linter)` |
| `cargo/lint` (Clippy) | 0 | `crates/ruff_text_size/src/size.rs` 221 `dead_code`, 221 `clippy::ptr_arg`, 222 `clippy::len_zero`, 221 `unreachable_pub` | repository-relative `--> path:line:col`; warnings only, so status 0 |
| `gradle/lint` (Spotless ktlint) | 1 | `okhttp-sse/src/main/kotlin/okhttp3/sse/EventSources.kt` 18 `standard:no-wildcard-imports` | module-relative (`src/main/kotlin/...:L18`), in stderr's failure block |
| `maven/lint` (Checkstyle) | 1 | `README.md` 301 NoHttp | `[ERROR] README.md:[301,6] (extension) NoHttp: ...` |
| `ruby/lint` (RuboCop) | 1 | `app/lib/hashtag_normalizer.rb` 9 `Lint/UselessAssignment`, 10 `Style/RedundantReturn`, 10 `Style/StringConcatenation`, 10 `Style/StringLiterals` | repository-relative, `path:line:col: S: [Correctable] Cop: message` |
| `swift/lint` (SwiftLint) | 2 | `ElementX/Sources/Other/Extensions/Array.swift` 100 `force_cast` (error), 101 `force_unwrapping` (warning) | absolute (`<repo>/...`), `path:line:col: severity: message (rule)` |

### Go runs read per test

`AreaRuns/go/{baseline-base,baseline-head,build-fail}/` are 3 `go test -json` runs of a throwaway
module, so a baseline can hold 1 failing test while the head fails another, and a package can fail
to build beside failing tests. Each directory has `command`, `exit`, `stdout` and `stderr`; there is
no `change.diff`, since an environment variable or a build tag changes the run, not an edit.
Captured 2026-10-04 on macOS 26 (arm64) with go 1.27.0 (mise), `GOTOOLCHAIN=local`, `GOFLAGS=` and
`GOCACHE` under the scratch directory. The output names no machine path, so the capture ran no scrub.

The module, `example.com/gobase`:

- `go.mod`: `module example.com/gobase` and `go 1.27`.
- `alpha/alpha_test.go`: `TestPasses` passes; `TestFlaky` calls `t.Fatal("fails at the base commit")`
  on line 12; `TestTable` runs subtests `case_a` and `case_b`, and `case_b` calls
  `t.Errorf("%s fails", name)`.
- `beta/beta_test.go`: `TestNew` calls `t.Fatal("fails only after the change")` when
  `GOBASE_FAIL_NEW=1`.
- `beta/broken_test.go`: under `//go:build broken`, `func undefinedCall() int { return missing() }`.

`cap.sh <dir> <command>` writes `command`, runs it through `/bin/sh -c` with stdout and stderr to
their files, and writes the status to `exit`. From the module root:

```sh
$CAP $F/go/baseline-base "go test -json ./..."
GOBASE_FAIL_NEW=1 $CAP $F/go/baseline-head "go test -json ./..."
$CAP $F/go/build-fail "go test -json -tags broken ./..."
```

| Case | exit | What the events say |
|---|---|---|
| `go/baseline-base` | 1 | `alpha`: `TestFlaky`, `TestTable/case_b` and `TestTable` fail; `beta` passes |
| `go/baseline-head` | 1 | as `baseline-base`, and `beta`'s `TestNew` fails |
| `go/build-fail` | 1 | `beta` emits `build-output` and `build-fail`, then a package `fail` with `FailedBuild` and no test; `alpha` fails as in `baseline-base` |

### Other runners read per test

`AreaRuns/<runner>/{baseline-base,baseline-head,build-fail}/` for `python` (pytest), `vitest`, `jest`,
`gradle`, `maven`, `ruby` (RSpec), `swift` and `cargo` are runs of 1 throwaway project per runner,
with the test command discover now proposes, so each proves its report flag. In each project
`flaky` fails at both runs, a second test fails only when an environment variable is set
(`baseline-head`), and `build-fail` adds a failure no test result holds. `vitest/unhandled`,
`vitest/pnpm-head`, `jest/pnpm-head`, `maven/multi-module-build-fail` and `ruby/suite-hook-fail` are extra
runs.

Captured 2026-10-04 on macOS 26 (arm64). Tools went into scratch only (`MISE_DATA_DIR` and every
cache under `$SCRATCH`, mise 2025.12.7): Python 3.12.12 with pytest 9.1.1 (uv venv); node 22.23.3
with npm 10.9.9, and node 24.21.0 with pnpm 12.0.0 for the pnpm runs; vitest 5.0.3; jest 30.5.2 and
jest-junit 17.0.0; Temurin JDK 21.0.12 with Gradle 9.8.0 and Maven 3.10.0, JUnit Jupiter 5.13.4 and
Surefire 3.5.4; Ruby 3.4.11 (compiled by mise) with Bundler 2.6.9, rspec-core 3.13.6 and
rspec_junit_formatter 0.6.0; Apple Swift 6.2 (swiftlang-6.2.3.3.20); rustup with cargo 1.90.0.

`$CAP2`, `$SCRATCH/cap2.sh`, runs a command as the area runner does: through `/bin/sh -c` with stderr folded
into stdout (so `stderr` is empty), and `{junit}` expanded, quoted, to a fresh path. It keeps the
report as `junit.xml`, a Swift Testing report beside it as `junit-swift-testing.xml`, or a
directory of reports as `junit/`, then scrubs with `scrub2.sh`, which is `scrub.sh` above with
`R` the project directory (`pwd -P`, and `pwd` for `R_L`) and run over every file of the case:

```sh
#!/bin/sh
# cap2.sh <fixture-dir> <command with {junit}>
d="$1"; c="$2"; J="$SCRATCH/report/out.xml"
/bin/rm -rf "$SCRATCH/report" "$d"; mkdir -p "$SCRATCH/report" "$d"
printf '%s\n' "$c" > "$d/command"
q="'$J'"
expanded=$(printf '%s' "$c" | sed "s#{junit}#$q#g")
/bin/sh -c "exec 2>&1
$expanded" > "$d/stdout"
echo $? > "$d/exit"
: > "$d/stderr"
if [ -d "$J" ]; then mkdir -p "$d/junit"; for f in "$J"/*.xml; do [ -f "$f" ] && /bin/cp -f "$f" "$d/junit/"; done
elif [ -f "$J" ]; then /bin/cp -f "$J" "$d/junit.xml"; fi
for f in "$SCRATCH"/report/out-*.xml; do [ -f "$f" ] && /bin/cp -f "$f" "$d/$(basename "$f" | sed 's/^out/junit/')"; done
"$SCRATCH/scrub2.sh" "$d"
```

The projects, each a directory of its own:

- `python`: `pyproject.toml` with `[project] name = "pybase"` and `[tool.pytest.ini_options]
  testpaths = ["tests"]`; `tests/test_alpha.py` with `test_passes`, `test_flaky` (`assert False,
  "fails at the base commit"`) and `TestTable.test_case_a`; `tests/test_beta.py`, where `test_new`
  asserts `not FAIL_NEW` read from `PYBASE_FAIL_NEW`; `conftest.py` imports `missing_helper` when
  `PYBASE_BROKEN=1`.
- `vitest`: `package.json` with `"test": "vitest run"` and `"type": "module"`, `npm install -D
  vitest@latest`; `test/alpha.test.js` (`alpha > passes`, `alpha > flaky`), `test/beta.test.js`
  (`new` fails when `VITESTBASE_FAIL_NEW=1`), `test/broken.test.js` (awaits `import
  ("./missing-helper.js")` when `VITESTBASE_BROKEN=1`), `test/late.test.js` (throws from a
  `setTimeout` after its test when `VITESTBASE_LATE=1`).
- `jest`: `package.json` with `"test": "jest"`, `npm install -D jest@latest jest-junit@latest`; the
  same 3 test files as `vitest` in CommonJS, with `JESTBASE_` variables and `require
  ("./missing-helper")`.
- `vitest-pnpm` and `jest-pnpm`: copies of those 2 with no `node_modules`, installed by `pnpm install
  --store-dir $SCRATCH/pnpm-store` under node 24, with a `pnpm-workspace.yaml` `allowBuilds` list
  for the packages whose install scripts pnpm 12 otherwise refuses.
- `gradle`: `settings.gradle` includes `alpha` and `beta`; the root `build.gradle` applies `java`
  with JUnit Jupiter to both. `alpha/.../AlphaTest.java` has `passes()` and `flaky()`;
  `beta/.../BetaTest.java` has `fresh()`, failing when `GRADLEBASE_FAIL_NEW` is set.
- `maven`: 1 `pom.xml` (`mavenbase`, release 21, JUnit Jupiter, Surefire 3.5.4); `AlphaTest` with
  `passes()` and `flaky()`, `BetaTest.fresh()` failing when `MAVENBASE_FAIL_NEW` is set.
  `maven-multi` is a parent `pom.xml` with modules `alpha` (`AlphaTest.flaky()`) and `beta`, whose
  `BetaTest` calls an undefined `undefinedHelper()`.
- `ruby`: a `Gemfile` with `rspec ~> 3.13` and `rspec_junit_formatter ~> 0.6`, `BUNDLE_PATH` under
  scratch; `spec/alpha_spec.rb` (`alpha passes`, `alpha flaky`), `spec/beta_spec.rb` (`beta new`,
  failing when `RSPECBASE_FAIL_NEW=1`), `spec/broken_spec.rb` (`require_relative "missing_helper"`
  when `RSPECBASE_BROKEN=1`); after the other Ruby runs, `spec/teardown_spec.rb` adds an
  `after(:suite)` hook that raises when `RSPECBASE_TEARDOWN=1`.
- `swift`: `Package.swift` (tools 6.0) with target `SwiftBase` (`public func sum`) and test target
  `SwiftBaseTests`: XCTest `AlphaTests` with `testPasses` and `testFlaky`, and Swift Testing
  `@Test func fresh()` expecting `SWIFTBASE_FAIL_NEW` unset; `swift build --build-tests` first.
- `cargo`: crate `cargobase` (edition 2021) with a doc test on `sum`, unit tests `tests::passes`
  and `tests::flaky` in `src/lib.rs`, and `tests/beta.rs` whose `mod tests` has its own `flaky`,
  failing when `CARGOBASE_FAIL_NEW` is set; `PATH=$CARGO_HOME/bin:$PATH RUSTUP_TOOLCHAIN=1.90.0`.

Each `build-fail` that isn't a variable adds 1 line and removes it after the run: Gradle and Maven
add `undefinedHelper();` as `fresh()`'s first line (`perl -pi -e 's/(void fresh\(\) \{)/$1\n
undefinedHelper();/'`), Swift adds `undefinedHelper()` to `fresh()`, cargo `undefined_helper();` to
`tests/beta.rs`'s `flaky`. Gradle captures ran after `rm -rf alpha/build beta/build`; the Maven
captures ran in order with no clean, so `build-fail` ran with the earlier runs' reports still in
`target/surefire-reports`. From each project directory, with `G` the Gradle collection and `M` the
Maven one:

```sh
G="mkdir -p {junit} && gradle test --continue; status=\$?; find . -path '*/build/test-results/*' -name '*.xml' -newer {junit} -exec cp {} {junit} ';'; exit \$status"
M="mkdir -p {junit} && mvn test; status=\$?; find . -path '*/target/surefire-reports/*' -name 'TEST-*.xml' -newer {junit} -exec cp {} {junit} ';'; exit \$status"
C='python -m pytest --junitxml={junit}'
$CAP2 $F/python/baseline-base "$C"; PYBASE_FAIL_NEW=1 $CAP2 $F/python/baseline-head "$C"
PYBASE_BROKEN=1 PYBASE_FAIL_NEW=1 $CAP2 $F/python/build-fail "$C"
C='npm run test -- --reporter=default --reporter=junit --outputFile.junit={junit}'
$CAP2 $F/vitest/baseline-base "$C"; VITESTBASE_FAIL_NEW=1 $CAP2 $F/vitest/baseline-head "$C"
VITESTBASE_BROKEN=1 VITESTBASE_FAIL_NEW=1 $CAP2 $F/vitest/build-fail "$C"
VITESTBASE_LATE=1 $CAP2 $F/vitest/unhandled "$C"
C='JEST_JUNIT_OUTPUT_FILE={junit} JEST_JUNIT_REPORT_TEST_SUITE_ERRORS=true npm run test -- --reporters=default --reporters=jest-junit'
$CAP2 $F/jest/baseline-base "$C"; JESTBASE_FAIL_NEW=1 $CAP2 $F/jest/baseline-head "$C"
JESTBASE_BROKEN=1 JESTBASE_FAIL_NEW=1 $CAP2 $F/jest/build-fail "$C"
VITESTBASE_FAIL_NEW=1 $CAP2 $F/vitest/pnpm-head 'pnpm run test --reporter=default --reporter=junit --outputFile.junit={junit}'   # in vitest-pnpm
JESTBASE_FAIL_NEW=1 $CAP2 $F/jest/pnpm-head 'JEST_JUNIT_OUTPUT_FILE={junit} JEST_JUNIT_REPORT_TEST_SUITE_ERRORS=true pnpm run test --reporters=default --reporters=jest-junit'   # in jest-pnpm
$CAP2 $F/gradle/baseline-base "$G"; GRADLEBASE_FAIL_NEW=1 $CAP2 $F/gradle/baseline-head "$G"
GRADLEBASE_FAIL_NEW=1 $CAP2 $F/gradle/build-fail "$G"
$CAP2 $F/maven/baseline-base "$M"; MAVENBASE_FAIL_NEW=1 $CAP2 $F/maven/baseline-head "$M"
MAVENBASE_FAIL_NEW=1 $CAP2 $F/maven/build-fail "$M"
$CAP2 $F/maven/multi-module-build-fail "$(printf '%s' "$M" | sed 's/mvn test/mvn -fae test/')"   # in maven-multi
C='bundle exec rspec --format progress --format RspecJunitFormatter --out {junit}'
$CAP2 $F/ruby/baseline-base "$C"; RSPECBASE_FAIL_NEW=1 $CAP2 $F/ruby/baseline-head "$C"
RSPECBASE_BROKEN=1 RSPECBASE_FAIL_NEW=1 $CAP2 $F/ruby/build-fail "$C"
RSPECBASE_TEARDOWN=1 $CAP2 $F/ruby/suite-hook-fail "$C"
C='swift test --parallel --xunit-output {junit}'
$CAP2 $F/swift/baseline-base "$C"; SWIFTBASE_FAIL_NEW=1 $CAP2 $F/swift/baseline-head "$C"
SWIFTBASE_FAIL_NEW=1 $CAP2 $F/swift/build-fail "$C"
C='cargo test --no-fail-fast'
$CAP2 $F/cargo/baseline-base "$C"; CARGOBASE_FAIL_NEW=1 $CAP2 $F/cargo/baseline-head "$C"
CARGOBASE_FAIL_NEW=1 $CAP2 $F/cargo/build-fail "$C"
```

What the runs show, beyond `flaky` failing in every `baseline-*` run and the second test in every
`baseline-head` run:

| Case | exit | Report |
|---|---|---|
| `python/build-fail` | 4 | none: `ImportError while loading conftest` before any test ran |
| `vitest/build-fail` | 1 | the suite that didn't load is a failing case named `test/broken.test.js` |
| `vitest/unhandled` | 1 | a case in suite `vitest unhandled errors` with an `<error>` for the late throw |
| `jest/build-fail` | 1 | 2 `Test suite failed to run` cases for `test/broken.test.js`; without `JEST_JUNIT_REPORT_TEST_SUITE_ERRORS=true` a probe run left the suite out of the report |
| `gradle/*` | 1 | `junit/` holds 1 file per test class; in `build-fail` only `AlphaTest`'s, beside `Execution failed for task ':beta:compileTestJava'` |
| `maven/build-fail` | 1 | none: `testCompile` failed, and the older reports in `target/surefire-reports` were not newer than `{junit}` |
| `maven/multi-module-build-fail` | 1 | `AlphaTest`'s report only, beside `[ERROR] Failed to execute goal ...maven-compiler-plugin...:testCompile ... on project beta` |
| `ruby/build-fail` | 1 | 0 cases: `0 examples, 0 failures, 1 error occurred outside of examples` |
| `ruby/suite-hook-fail` | 1 | only `alpha flaky` fails in the report; the output ends `4 examples, 1 failure, 1 error occurred outside of examples` |
| `swift/baseline-*` | 1 | XCTest's cases in `junit.xml`, Swift Testing's in `junit-swift-testing.xml`; `fresh()` fails only in the second |
| `swift/build-fail` | 1 | none: `error: cannot find 'undefinedHelper' in scope` |
| `cargo/baseline-head` | 101 | no report; libtest prints `test tests::flaky ... FAILED` under both `Running unittests src/lib.rs` and `Running tests/beta.rs` |
| `cargo/build-fail` | 101 | none: `error: could not compile` before any test ran |

Probes that decided the flags, run in the same projects and not kept: `mvn test
-Dsurefire.reportsDirectory=<dir> -DreportsDirectory=<dir>` still wrote only
`target/surefire-reports`, so Gradle and Maven collect their reports into `{junit}` instead;
`swift test --xunit-output <dir>/out.xml` without `--parallel` wrote only
`out-swift-testing.xml`.

## Run view: a prove gate

`RunView/prove-gate/{gate,test}.jsonl` are the `gate` and `test` streams of 1 real
`check --tier push --prove` run over a throwaway package, so the run view reads real
`prove.result` events and `gate.step` start offsets. Captured 2026-10-04 with Swift 6.2.3, from a
`swiftgate` debug build of this commit's sources.

The repository, made in `mktemp -d`, holds `Packages/Calc` (a `Calc` library and a `CalcTests`
target, swift-tools-version 6.2) and a `.swiftgate.toml` declaring `Calc` a `library` module.
It has 3 commits. `base` holds an `add` function and its test. `surface` adds `double` and
`clamp`, both returning `x` unchanged. `behaviour` writes their bodies and adds
`DoubleTests.swift`: a `#expect` test of `double`, a `#expect` test of an in-range `clamp`, a
`try #require` test of a low `clamp`, and an XCTest of `double`. From that repository:

```sh
LLVM_PROFILE_FILE=<scratch>/p-%p.profraw <harness>/plugin/gate/.build/debug/swiftgate \
  check --tier push --base <base sha> --prove --proof-base <surface sha>
cp .harness/events/gate.jsonl .harness/events/test.jsonl <fixtures>/RunView/prove-gate/
```

The run was RED, as built to be: the in-range `clamp` test passes with `clamp` reverted to the
surface. At the merge base all 4 tests were compile-only, so prove retried them at the surface
sha. The streams hold 1 `gate.run`, 11 `gate.step` (every one but `record` with a `startMs`),
5 `test.result` and 4 `prove.result`: 3 `proven` (kinds `expect`, `require`, `xct-assert`) and 1
`passes-reverted`, each with the surface sha as `proofBase`. The capture copied both files
unedited:
`grep -rniE '/Users|/private|/var/folders|/tmp|caleb|@[a-z]+\.|swift-harness|home' RunView/prove-gate`
matched nothing.

## Run view: a run with spans

`RunView/build-run-2/` repeats the `build-run-1` capture once the skills and `build-task.js` record
spans, gates record `prove.result` and `events ingest` writes `agent.tools`. `SOURCE` in that
directory holds every command, the Claude Code version, the date and the build run id,
`20261004T095203Z-7053bb32`. The setup, the spec, the commands and the copies are `build-run-1`'s,
with 1 change: the `capture` preset sets `task_proof = "per-task"`, so each task gate runs
`--prove --mutate`. The PreToolUse guard that limits review agents' Bash to span lines was not on
`main` yet; the preset's `review = "gate"` runs no review agent, so it had nothing to limit.

The decomposer again split the 2 requirements into 3 tasks, this time in 2 waves, and the first 2
ran in parallel:

| Task | Ledger status | What happened |
|---|---|---|
| `counter-core-reset-and-decrement-floor` | `done` | task gate GREEN with prove 3 of 3, merged, merge gate GREEN |
| `counter-ui-reset-button` | `done` | its merge turned the push gate RED (a stale snapshot), `build merge --undo`, the fixer re-recorded the snapshot, the fix merge GREEN |
| `counter-ui-snapshot-rerecord-with-reset` | `abandoned` | returned no commits, `build-return.no-commits` halted it; the resumed session answered `abandon`, an orchestrator-answered rehearsal, never the user |

The final `ready` gate, run `20261004T101604Z-f2ecc518`, was GREEN.

| File | Holds |
|---|---|
| `events/span.jsonl` | 5 spans, each started and ended once: 3 `worker` (1 per task, `--task` set, no parent), `final` and `ship` |
| `events/usage.jsonl` | 90 `agent.usage` and 29 `agent.tools`, from the skills' own `events ingest` calls |
| `events/test.jsonl` | 201 `test.result` and 3 `prove.result`, all from the final gate |
| `events/<stream>.jsonl` | the main store's `build` (1 halt, 1 resume), `gate` (20 `gate.run`, 91 `gate.step`), `hook` and `cache` streams, whole, preflight gates included |
| `events/imported/<store>/` | the 3 task worktree stores `worktree remove` imported, with their `store.json`; the fixer's holds its `snapshots record` and `check push` runs |
| `ledger.json`, `ledger-events.jsonl` | the plan's ledger and its build run's `events.jsonl` |
| `returns/<task>.json` | the 2 checked returns; the abandoned task's was refused, so none was written |
| `run.json`, `plan.json`, `plan.md`, `spec.md` | the build run record, the plan state, the spec page and the spec |

No store holds either task gate the returns name (`20261004T095307Z-577bdbaf`,
`20261004T095306Z-43d546a1`), so no `prove.result` names a task. The worker prompt says
`swiftgate check`, and on the capture machine `swiftgate` on `PATH` was an older installed plugin,
not the plugin under test; the fixer ran the plugin's own `bin/swiftgate`, and its runs recorded.
`build-run-1` lost its task gates the same way.

The sources held no machine path, so no `sed` ran.
`grep -rniE '/Users|/private|/var/folders|/tmp|caleb|@[a-z]+\.|swift-harness|home' RunView/build-run-2`
and `grep -rniE 'sk-ant|api[_-]?key|ANTHROPIC|bearer|password|secret|token=' RunView/build-run-2`
matched nothing. Each `agent.tools` `files` list is empty: the ingest that wrote them dropped
every path, for 2 reasons `Transcripts/worker-worktrees/` now covers. A worker's transcript names
the main checkout as its `cwd`, so a path in its own worktree sat outside that top level; and the
top level lookup standardised the `/private/var/…` `cwd` to `/var/…`, so no path matched even there.

## Run view: a brownfield run's pre-build phases

`RunView/brownfield-prebuild/events/{brownfield,span}.jsonl` are the `brownfield` and `span`
streams of a real brownfield clone taken from discovery to the final span, for the run view's
discover and warm-up spans and its folding of the phases before `build start` into the build run.
Captured 2026-10-04 with Node 22, from a `swiftgate` debug build of this commit's sources.

The clone, made in `mktemp -d`, is an npm workspace with 2 packages, `packages/api` and
`packages/web`, each with a `test` and a `build` script that exit 0. The spans name the plan slug
and the build run of `RunView/build-run-1/`, so a reader test can seed that run's plan state
beside them. From `plugin/gate` after `swift build`:

```sh
SG=$PWD/.build/debug/swiftgate T=$(mktemp -d) && cd $T && export LLVM_PROFILE_FILE=$T/p-%p.profraw GIT_CONFIG_GLOBAL=/dev/null && mkdir clone && cd clone
git init -q -b main
printf '{"name":"clone","private":true,"workspaces":["packages/*"]}\n' > package.json
for a in api web; do mkdir -p packages/$a; printf '{"name":"%s","version":"1.0.0","scripts":{"test":"node -e \\"process.exit(0)\\"","build":"node -e \\"process.exit(0)\\""}}\n' $a > packages/$a/package.json; done
git add -A && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m base
SLUG=2026-10-03-counter-reset-and-floor RUN=20261004T045528Z-58d28c78
$SG discover --apply      # exit 0, 2 areas, 4 guessed commands
$SG warmup                # exit 0, every step passed, cold
for phase in spec-read explore plan contract; do
  S=$($SG events span start --phase $phase --build-run $SLUG --role orchestrator); sleep 1
  $SG events span end $S --outcome ok
done
F=$($SG events span start --phase final --build-run $RUN --role orchestrator); sleep 1
$SG events span end $F --outcome ok
cp .git/swift-harness/events/brownfield.jsonl .git/swift-harness/events/span.jsonl <fixtures>/RunView/brownfield-prebuild/events/
```

The streams hold 1 `discover.run`, 4 `warmup.run` and 5 spans. The warm-up wrote 1 event per area
and step, an area's 2 together when the area finished. 4 spans name the slug, as the run skill's
phases before `build start` do, and `final` names the build run. The capture copied both files
unedited:
`grep -rniE '/Users|/private|/var/folders|/tmp|caleb|@[a-z]+\.|swift-harness|home' RunView/brownfield-prebuild`
matched nothing.

## Run report: a run that left tasks unfinished

`RunReport/memos-2/{ledger.json,build-events.jsonl}` are the final `ledger.json` and the build run's
`events.jsonl` of the second brownfield trial on `usememos/memos`, as
`evals/results/2026-10-04-brownfield-trial/memos-2/` keeps them. The build marked 2 tasks `blocked`,
left 1 `pending` and finished 1, and its `final` gate came back GREEN on the contract alone, so the
report must not lead with that verdict. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-trial/memos-2 F=plugin/gate/Tests/Fixtures/RunReport/memos-2
mkdir -p $F
sed -E 's#"/[^"]*/memos-2/#"/CLONE/#g' $S/ledger.json > $F/ledger.json
cp $S/build-events.jsonl $F/build-events.jsonl
```

The `sed` replaces the trial clone's absolute path in each task's `worktree` with `/CLONE/` and
changes nothing else.
