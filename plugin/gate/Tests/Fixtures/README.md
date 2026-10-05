# Test fixtures

Every file here is real tool output. Never edit one by hand: re-run its capture command.

Commands run from the repository root. Where output embeds absolute paths, the capture pipes it
through `sed "s#$ROOT#/REPO#g"` (with `ROOT=$(pwd)`) so fixtures carry no machine paths; tests
decode them with repository root `/REPO`.

## SwiftPM

Toolchain: Apple Swift 6.2 (swiftlang-6.2.3.3.20), macOS 26.

| File | Capture |
|---|---|
| `SwiftPM/describe-<Package>.json` (APIClient, AccessibilityIDs, CounterFeature, GameEngine, HTTPClient, LogClient) | `(cd examples/SampleApp/Packages/<Package> && swift package describe --type json) \| sed "s#$ROOT#/REPO#g"` |
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
| `no-match` | `ProbeTests\.NoSuchTest` | a filter that names no test in a target that has tests: exit 0, stderr `warning: No matching test cases were run`, both reports with `tests="0"`. Captured on its own with the `capture` function's command for this 1 scenario |
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
`plugin/gate/Fixtures/xcresult/capture.sh` (run from the repository root). It clones the pinned
simulator (iPhone 17, iOS 26.2), copies `examples/SampleApp/Packages` to a scratch directory, adds
`plugin/gate/Fixtures/xcresult/XcresultProbeTests.swift` to the copy's `CounterUISnapshotTests` target,
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
| `missing-test` | `ProbePassXCTests/testNoSuchTest` (`capture.sh missing-test`) | exit 0; a method missing from a real class runs nothing, the same childless `Test Plan` node |
| `one-test` | `ProbePassXCTests/testAdds` (`capture.sh one-test`) | exit 0; 1 passed `Test Case` |
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

### Kept flows: activities and screen recordings

`plugin/gate/Fixtures/xcresult/capture-flow-video.sh` captures `Xcresult/activities/<scenario>/`
(run from anywhere, with `SWIFTGATE=<binary>` to pin the build): a scratch git copy of
`examples/SampleApp`, whose test plan sets `uiTestingScreenshotsLifetime` to `keepAlways` and
`preferredScreenCaptureFormat` to `screenRecording`, runs `swiftgate test --tier t3 --json` on the
harness's own clone. Per scenario the script saves `tests.json` (`xcrun xcresulttool get
test-results tests`), `<method>.activities.json` for each UI test (`xcrun xcresulttool get
test-results activities --test-id <Class>/<method>()`), and `manifest.json` from `xcrun xcresulttool
export attachments --output-path <dir>`. The MP4s stay out of the repository. The scratch path
becomes `/SCRATCH`, the clone's name `swift-harness-PID-TOKEN` and its UDID `CLONE-UDID`.

| Scenario | Change | What it shows |
|---|---|---|
| `pass` | as committed | GREEN; each test keeps 1 `Screen Recording <date>.mp4` and 1 `Synthesized Event` attachment per tap |
| `fail` | the counter test expects `"7"` | RED; the failing test still keeps its recording; its activities end with a top-level `XCTAssertEqual failed: …` activity with `isAssociatedWithFailure` true, then `Tear Down` |
| `no-video` | the plan's lifetime is `deleteOnSuccess` | GREEN; the manifest lists no `.mp4` for either passing test |

Observed: a screen recording's attachment `timestamp` equals the start of the
`kXCTAttachmentScreenRecording` child of `Start Test at …`, and the MP4's length (5.04 s by
`ffprobe`) matches the span from that timestamp to `Tear Down`, so the timestamp is the video's first
frame. Every test's top level reads `Start Test at <date>`, `Set Up`, its actions, `Tear Down`.

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

## AgentDevice

Captured on 2026-10-04 with `agent-device` 0.21.18, Xcode 26.2 and the iOS 26.2 runtime. The pin
is `AgentDevicePin.version`; install it with:

```
npm i -g agent-device@0.21.18
```

Build the app with `(cd examples/SampleApp && ../../plugin/bin/swiftgate test --tier t3)`, then run
`plugin/gate/Tests/Fixtures/AgentDevice/capture.sh
examples/SampleApp/.harness/derived-data/app-SampleApp/Build/Products/Debug-iphonesimulator/SampleApp.app`
from the repository root. The script creates its own `agent-device-capture-<pid>` iPhone 17 device,
installs the app, and deletes the device on exit. Each `AgentDevice/<call>.{stdout,stderr,status}`
is 1 real call against session `swiftgate-capture` on that device; the script replaces the scratch path
with `/SCRATCH` and `$HOME` with `/HOME`. The same script writes
`plugin/qa/agent-device-schemas-0.21.18.json`: the MCP server's `initialize` `serverInfo` and its
`tools/list` `tools`, from `agent-device mcp` over stdio.

| Files | Call |
|---|---|
| `version` | `--version` |
| `open`, `open-launch-args.txt` | `open com.example.SampleApp --udid <udid> --session <session> --launch-args -harness-scenario --launch-args live --json`, then the app process's argv from `ps` |
| `snapshot`, `screenshot`, `appstate`, `session-list` | `snapshot`, `screenshot <path>`, `appstate`, `session list`, each with `--udid <udid> --session <session> --json` |
| `wait-text-absent`, `wait-text-absent-plain` | `wait text "No such text anywhere" 2000`, with and without `--json` |
| `open-device-in-use` | `open` on the same device from session `<session>-other` |
| `open-unknown-udid` | `open` with UDID `00000000-0000-0000-0000-000000000000` |
| `batch-pass`, `batch-fail`, `batch-invalid`, `batch-record` | `batch --steps-file <file> --on-error stop`: a passing `wait`, `press`, `is`, `snapshot` flow; a flow whose second step waits for absent text; a `wait` step with a CLI-shaped `target`; a flow wrapped in `record start` and `record stop` steps |
| `record-start`, `record-stop`, `contact-sheet` | `record start <path>`, a `press`, `record stop`, `record contact-sheet <video> --out <sheet> --json` |
| `logs-path`, `network-dump`, `trace-start`, `trace-stop` | `logs path`, `network dump 25 --include headers`, `trace start <path>`, `trace stop <path>` |
| `close` | `close` |
| `close-session-not-found` | `close --udid 00000000-0000-0000-0000-000000000000 --session swiftgate-capture-closed --json`, a session never opened |
| `device-release-session-refused`, `device-release-stale` | `device release --stale` with `--udid --session`, then with `--udid` alone |

Observed behavior the adapter relies on:

- `--json` prints its envelope on stdout, `{"success":true,"data":…}` or
  `{"success":false,"error":{"code","message",…}}`, and leaves stderr empty. A failure exits 1.
  Without `--json`, a failure prints `Error (<code>): <message>` on stderr and nothing on stdout.
- The codes seen are `COMMAND_FAILED` (a `wait` past its deadline, with `details.reason`
  `wait_deadline_exceeded`) and `DEVICE_IN_USE` (`open` on a device another session holds). Others are
  `DEVICE_NOT_FOUND` (an unknown UDID), `SESSION_NOT_FOUND` (`close` on a session that isn't
  open) and `INVALID_ARGS` (a step input that fails its schema, and `--session` on `device`, which
  refuses it).
- A failing batch names the step in `error.details.step` (1-based) and `error.details.command`;
  a passing one lists every step under `data.results` with `step`, `command`, `ok` and
  `durationMs`, and a `snapshot` step returns the full tree under its `data.nodes`.
- `record start` and `record stop` work as steps inside a batch that also drives the app.
- `open --launch-args` reaches the app: the app process's argv ends `-harness-scenario live`.
- `open` with `--udid` and `--session` binds the session to that device: `session list` and the
  envelope's `device_udid` name it.
- No call failed for a missing macOS Accessibility or Screen Recording permission: `snapshot`,
  `screenshot` and `record` all succeeded on this Mac, so `doctor` gets no permission check.
- `appstate` prints `data.state`, one of the 5 `XCUIApplication.State` names in the package's
  `dist/src` (`unknown`, `notRunning`, `runningBackgroundSuspended`, `runningBackground`,
  `runningForeground`).
- The iOS role vocabulary is a node's `type`. The runner names each element type from
  `elementTypeNamesByRawValue` in
  `dist/apple/runner/AgentDeviceRunner/AgentDeviceRunnerUITests/RunnerTests+Snapshot.swift`.
  The names are `Application`, `Window`, `Button`, `Cell`, `StaticText`, `TextField`, `TextView`,
  `SecureTextField`, `Switch`, `Slider`, `Link`, `Image`, `NavigationBar`, `TabBar`,
  `CollectionView`, `Table`, `ScrollView`, `Toolbar`, `SearchField`, `SegmentedControl`, `Stepper`,
  `Picker`, `ActivityIndicator`, `ProgressIndicator`, `CheckBox`, `MenuItem`, `WebView`, `Other`,
  `Keyboard` and `Key`, and any other type as `Element(<raw value>)`. The snapshot engine in
  `dist/src/ios-snapshot-engine.js` also rewrites some `Other` nodes to `Heading`.

### AgentDevice/seeded

Two real `sim up` and `sim snap` runs against `examples/SampleApp` on 2026-10-04, with `agent-device`
0.21.18 on a clone `sim up` made from the configured iPhone 17 (iOS 26.2). The seeded run had this
local diff applied to `Packages/CounterFeature/Sources/CounterUI/CounterView.swift`, below the
`counter.fact` button; nobody committed it, and `git checkout -- Packages` removed it after the
capture:

```swift
      Button("Share") {}

      Button {} label: { Circle().frame(width: 44, height: 44) }
        .accessibilityIdentifier("counter.dot")
```

The clean run used the app as committed. Each run, from `examples/SampleApp`, with the worktree's
`swift build --product swiftgate`:

```
../../plugin/gate/.build/debug/swiftgate sim up --json
../../plugin/gate/.build/debug/swiftgate sim snap "counter screen" --assert "Cat fact" --json
agent-device close --udid <udid> --session <session> --json
rm <lock dir>/sim-leases/<runID>.json
```

Removing the lease makes the holder delete the clone and free its slot. The capture scrubbed nothing: no
file holds a local path.

| Files | From |
|---|---|
| `AgentDevice/seeded/unlabeled-controls.tree.json` | the seeded run's `sim/steps/001.tree.json`: a `Button` labelled `Share` with no identifier, and a `Button` with identifier `counter.dot` and no label |
| `AgentDevice/seeded/clean.tree.json` | the clean run's `sim/steps/001.tree.json` |
| `gate/Fixtures/seeds/sim-verify/unlabeled-controls/sim/`, `gate/Fixtures/seeds/sim-verify/valid/sim/` | each run's `session.json`, `steps.ndjson`, `steps/001.png` and `steps/001.tree.json`, unmodified |

### AgentDevice/batch

The batches `qa run` drives, captured on 2026-10-04 with `agent-device` 0.21.18 on a clone
`swiftgate sim up` made from the configured iPhone 17 (iOS 26.2), against `examples/SampleApp` as
committed. From the repository root, with the worktree's `swift build --product swiftgate`:

```
plugin/gate/Tests/Fixtures/AgentDevice/batch/capture.sh plugin/gate/.build/debug/swiftgate
```

The script runs `sim up --json` in `examples/SampleApp`, runs each batch with `--udid` and
`--session` from its output, and runs `sim down` on exit. `<name>.steps.json` is the input: the
counter flow (`QA/counter.flow.json`) with the `snapshot`, `screenshot` and `snapshot` steps
`qa run` adds after each assertion, its screenshot paths under `/SCRATCH`, which the script points
at a scratch folder. In each output the script replaces the scratch path with `/SCRATCH`, `$HOME` with
`/HOME`, the clone's UDID with `UDID` and the session with `SESSION`.

| Files | Batch |
|---|---|
| `pass.{steps.json,stdout,stderr,status}` | the driven counter flow on a fresh launch: every step passes |
| `fail.{steps.json,stdout,stderr,status}` | the same flow run next, expecting `5`: step 6, the `is`, fails |

Observed behavior the runner relies on:

- A `screenshot` step writes its PNG at its `input.path`, and a `snapshot` step's `data` holds the
  tree a `snapshot --json` envelope holds under `data`.
- A failing `is` exits 1 with `COMMAND_FAILED`, `details.reason` `predicate_failed`,
  `details.step` and `details.command`, and the steps before it under
  `details.partialResults`, each with its `data`.

### AgentDevice/covered

A batch that stops on a failure reason the 3 original cases didn't name, captured on 2026-10-04
with `agent-device` 0.21.18 on a clone `swiftgate sim up` made from the configured iPhone 17
(iOS 26.2). The iOS validation trial's second attempt on `Aidoku/Aidoku`
(`evals/results/2026-10-04-brownfield-ios-validation-2/`, finding 4) hit it pressing a SwiftUI
toggle that hides its label, but kept no batch output. The capture repeats that shape on
`examples/SampleApp` with `change.diff` applied: 1 such toggle, `id="counter.confirm"`. From the
repository root:

```
plugin/gate/Tests/Fixtures/AgentDevice/covered/capture.sh plugin/bin/swiftgate
```

The script applies `change.diff`, runs `sim up --json` in `examples/SampleApp`, runs the batch
with `--udid` and `--session` from its output, and on exit runs `sim down` and reverts the diff.
`press-switch.flow.json` is the flow as a validation worker writes it, and
`press-switch.steps.json` the batch `qa run` drives from it, its screenshot paths under
`/SCRATCH`. The script scrubs the outputs as in `AgentDevice/batch`.

| Files | Batch |
|---|---|
| `press-switch.{steps.json,stdout,stderr,status}` | wait for the counter, then press the toggle by its id: step 5, the `press`, exits 1 with `COMMAND_FAILED`, `details.reason` `covered_by_interactive_descendants`, `details.step` 5 and the 4 steps before it under `details.partialResults` |

### AgentDevice/record

What `qa run --final` calls around 1 flow, captured on 2026-10-04 with `agent-device` 0.21.18 and
Xcode 26.2 on a clone `swiftgate sim up` made from the configured iPhone 17 (iOS 26.2), against
`examples/SampleApp` as committed. From the repository root, with the worktree's
`swift build --product swiftgate`:

```
plugin/gate/Tests/Fixtures/AgentDevice/record/capture.sh plugin/gate/.build/debug/swiftgate
```

The script runs `sim up --json` in `examples/SampleApp`, makes every call with `--udid` and
`--session` from its output, and runs `sim down` on exit. `recorded-pass.steps.json` and
`recorded-fail.steps.json` are inputs: `AgentDevice/batch/pass.steps.json` and `fail.steps.json`
with `{"command":"record","input":{"action":"start","path":"/SCRATCH/video.mp4"}}` put first. In
each output the script replaces the scratch path with `/SCRATCH`, `$HOME` with `/HOME`, the clone's UDID
with `UDID` and the session with `SESSION`.

| Files | Call |
|---|---|
| `logs-start`, `logs-stop`, `logs-path` | `logs start` before the batches, then `logs stop` and `logs path` after them |
| `recorded-pass`, `record-stop`, `contact-sheet` | the recorded counter flow on a fresh launch, `record stop`, then `record contact-sheet /SCRATCH/video.mp4 --out /SCRATCH/sheet.png --json` |
| `recorded-fail`, `record-stop-after-fail` | the recorded flow run next, expecting `5`: step 7, the `is`, fails; then `record stop` |
| `record-start-beside-outside` | `record start` while `xcrun simctl io <udid> recordVideo` runs on the same device |
| `network-dump` | `network dump 25 --include headers` |
| `app-container` | `xcrun simctl get_app_container <udid> com.example.SampleApp data` |
| `log-show` | `xcrun simctl spawn <udid> log show --style compact --info --debug --predicate 'subsystem == "com.example.SampleApp"' --start <time before sim up>` |

Observed behavior the final pass relies on:

- A batch whose first step is `record start` reports that step's `durationMs`; the steps after it
  sum to `totalDurationMs` less it. The passing video's sheet spans 4833 ms, the 4476 ms of steps
  after `record start` plus the `record stop` call, so the video starts when `record start` ends.
- A recording started inside a batch outlives the batch, failed or passed: `record stop` after it
  returns the video.
- `network dump` parses the session app log, so the stream runs for the whole flow.
- SampleApp logs only on a failed fact request, so its subsystem's `log show` is a header line.
- `apple_simulator_recording_busy` didn't occur: `record start` succeeded beside an outside
  `simctl recordVideo` on the same device, and 2 recordings on 2 clones also both started. The
  reason comes from the installed package's
  `dist/src/platform-runtime-screen-recording-apple-simulator-host.js`, which maps
  `simctl recordVideo`'s exit 16 to `DEVICE_IN_USE` with that reason. Tests build that failure as a
  value; no fixture holds it.

### AgentDevice/crash

A real `sim up` run against `examples/SampleApp` on 2026-10-04, with `agent-device` 0.21.18 on a
clone `sim up` made from the configured iPhone 17 (iOS 26.2), then a `SIGABRT` that ended its app.
The iOS runtime has no `kill`, so `xcrun simctl spawn <udid> kill -ABRT <pid>` fails with
`NSPOSIXErrorDomain` code 2; a simulator app is a Mac process, so the Mac's `kill` reaches it. From
`examples/SampleApp`, with the worktree's `swift build --product swiftgate`:

```
../../plugin/gate/.build/debug/swiftgate sim up --json
../../plugin/gate/.build/debug/swiftgate sim snap "counter screen" --json
xcrun simctl spawn <udid> launchctl list | grep SampleApp
ps -o pid,command -p <pid>
kill -ABRT <pid>
agent-device appstate --udid <udid> --session <session> --json
agent-device snapshot --udid <udid> --session <session> --json
agent-device screenshot <scratch>/after-crash.png --udid <udid> --session <session> --json
../../plugin/gate/.build/debug/swiftgate sim down --json
```

`launchctl list` gives the app's PID, and `ps` shows it is the run's device's `SampleApp`.
`crash/<call>.{stdout,stderr,status}` holds each `agent-device` call's stdout, stderr and exit
status, with `/HOME` for `$HOME` and `/SCRATCH` for the scratch path. The crash report is the file
macOS wrote in `~/Library/Logs/DiagnosticReports/`, unmodified; macOS had already written
`/Users/USER` for the home folder.

| Files | From |
|---|---|
| `AgentDevice/crash/appstate-not-running` | `appstate` 5 s after the kill |
| `AgentDevice/crash/snapshot-not-running` | `snapshot` after the kill |
| `AgentDevice/crash/screenshot-not-running` | `screenshot` after the kill |
| `AgentDevice/crash/SampleApp-2026-10-04-151000.ips` | the report macOS wrote for the kill |

Observed behavior `sim` relies on:

- After the crash, `appstate` exits 0 with `data.state` `notRunning`.
- `snapshot` fails with `COMMAND_FAILED`, message `app '<bundle id>' is not running` and
  `details.runnerErrorCode` `APP_NOT_RUNNING`; it doesn't relaunch the app. `screenshot` still
  succeeds and shows the home screen.
- The report appeared about 14 s after the crash, named `<process>-<yyyy-MM-dd-HHmmss>.ips`. Its
  first line is a JSON header; the rest is a JSON body whose `procPath` holds
  `CoreSimulator/Devices/<udid>/`, with `bundleInfo.CFBundleIdentifier`, `captureTime` (the crash,
  `yyyy-MM-dd HH:mm:ss.SSSS ±hhmm`) and `exception` `{type: EXC_CRASH, signal: SIGABRT}`.

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

`memos-3-worker-bash.json` holds the 4 Bash calls `guard.build-agent-main-checkout` denied 2 build
workers in the third brownfield trial on `usememos/memos` (2026-10-04,
`evals/results/2026-10-04-brownfield-trial/memos-3/`, finding 3). Each worker started in the
clone's main checkout and `cd`'d into its own task worktree first. Each entry is the call's
`agentType` (from the subagent's `.meta.json`), the transcript's `cwd`, the `tool_input.command`
and the denial text the hook returned. `T` is the session's `subagents/workflows` directory
under `~/.claude/projects/`, `C` the clone and `H` the harness checkout the trial ran:

```sh
F=plugin/gate/Tests/Fixtures/Hooks/memos-3-worker-bash.json T=… C=… H=… python3 - <<'PY'
import json, os, glob
T, C, H, F = (os.environ[k] for k in "TCHF")
calls = []
for path in sorted(glob.glob(f"{T}/*/agent-*.jsonl")):
    agent = json.load(open(path[:-len(".jsonl")] + ".meta.json"))["agentType"]
    uses = {}
    for line in open(path):
        entry = json.loads(line)
        content = entry.get("message", {}).get("content")
        if not isinstance(content, list): continue
        for block in content:
            if block.get("type") == "tool_use" and block.get("name") == "Bash":
                uses[block["id"]] = (block["input"]["command"], entry["cwd"])
            if block.get("type") == "tool_result" and block["tool_use_id"] in uses:
                text = json.dumps(block.get("content"))
                if "guard.build-agent-main-checkout" in text:
                    command, cwd = uses[block["tool_use_id"]]
                    calls.append({"agentType": agent, "cwd": cwd, "command": command,
                                  "denial": json.loads(text) if text.startswith('"') else text})
scrub = lambda s: s.replace(H, "/HARNESS").replace(C, "/CLONE")
out = json.dumps(calls, indent=2, ensure_ascii=False) + "\n"
open(F, "w").write(scrub(out))
PY
```

The scrub turns the harness checkout into `/HARNESS` and the clone into `/CLONE`, so the task
worktrees beside it read `/CLONE-spec-share-view-limit-web` and `-store`; nothing else changed.

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

### `Bootstrap/Scenario/`

Real `swiftgate bootstrap` runs on 2026-10-04 (Xcode 26.2), on `rsync` copies of
`examples/SampleApp` without `.harness`, `DerivedData`, `.build`, `.swiftpm` or `xcuserdata`, and
with `.swiftgate.toml` and `App/Scenario.swift` deleted, so the copy is the app before it adopted
the harness: 1 `@main … : App` file, `App/SampleApp.swift`. Not a git repository. Every command
ran with `HOME=<scratch>/home SWIFTGATE_CACHE_DIR=<scratch>/cache SWIFTGATE_BUILD_CONFIG=debug
<checkout>/plugin/bin/swiftgate`, written `SG` below. Scrubbing: the copy's path becomes `/REPO`,
the scratch home `/HOME`, the checkout's `plugin` directory `/PLUGIN`.

| File | Capture |
|---|---|
| `single-dry-run.stdout` | `SG bootstrap` in the copy (exit 0) |
| `single-apply.stdout` | `SG bootstrap --apply` next (exit 0) |
| `single-stamped-Scenario.swift`, `single-stamped.swiftgate.toml` | `App/Scenario.swift` and `.swiftgate.toml` as that apply wrote them, copied verbatim |
| `single-arch.stdout` | `SG arch` next (exit 1). Its 1 finding is `arch.undeclared-kind` for `GameEngine`, whose `[[modules]]` entry went with the deleted config; no `sim.scenario-drift` |
| `single-rerun-Scenario.swift`, `single-rerun.stdout` | `case empty` added after `case live` with `sed -i '' 's/^    case live$/    case live\n    case empty/' App/Scenario.swift`, then `SG bootstrap` (exit 0, `Nothing to do.`); the file is copied after the run, unchanged by it |
| `two-CompanionApp.swift` | Not tool output: the second `@main … : App` file written for the next run, copied to `Companion/CompanionApp.swift` in a fresh copy |
| `two-dry-run.stdout` | `SG bootstrap` in that copy (exit 0): no `Scenario.swift`, a commented `[[scenarios]]` example in the config, and a `consider:` note naming both entry points |

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

`swift/lint-not-installed` is the one case whose tool is missing on purpose: `swift/lint`'s linter
with `swiftlint` off `PATH`, as a run whose shell never activated the repository's tool manager sees
it. Captured 2026-10-04 on macOS 26.5.1 from a clone of `Aidoku/Aidoku` at
`3091ef26e593d303e34afed70bc8c5997c105f80`, with no edit, so it has no `change.diff`:

```sh
cd <clone> && c='swiftlint lint --config .swiftlint.yml Aidoku/Core/Downloads/Models/Download.swift'
printf '%s\n' "$c" > $F/swift/lint-not-installed/command
env -i HOME=/nonexistent PATH=/usr/bin:/bin /bin/sh -c "$c" \
  > $F/swift/lint-not-installed/stdout 2> $F/swift/lint-not-installed/stderr
echo $? > $F/swift/lint-not-installed/exit    # 127
```

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
into `junit.xml` too, which left those reports ill-formed XML, so a later capture replaced them with
the version under "Recaptured reports" below:

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

On 2026-10-04 the same commands ran again for every case that has a `junit.xml`. Those are
`gradle/test-{pass,fail,crash}`, `maven/test-{pass,fail}`, `node/test-{pass,fail}` and
`python/test-{pass,fail}`. The clones sat at the same commits and the tools at the same versions,
so each report is now well-formed XML. Each case's `stdout`, `stderr` and `exit` come from the same
run as its report. `git init; git fetch --depth 1 origin <sha>; git checkout FETCH_HEAD` made each
clone, and the tools went into a new scratch directory the same way. The scrub now escapes each
placeholder inside a report, so `<repo>` reads back from the XML as text:

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
Gradle and Maven captures ran `rm -rf okhttp-sse/build/test-results` or `rm -rf
target/surefire-reports` before each test run, as the original note says. The Gradle `test-pass`
run came after a warm-up, so its output holds no distribution download. The Gradle `test-crash`
command ran 8 times. 1 run reported 12 cases, as the original did, but with 2 failures; the
other 7 reported 2. The fixture keeps the fourth run: `retryInvalidFormatIgnored()` passed and the
report marks `multilineCrLf()` skipped. JUnit's method order there is not stable between runs.

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
| `gradle/test-crash` | 1 | 2 / 0, 1 skipped | stderr `Process 'Gradle Test Executor 4' finished with non-zero exit value 3`; the JUnit file marks the case running at the exit `<skipped/>` (`multilineCrLf()` in this run) and leaves `exits()` out, so JUnit alone reads as a pass |
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
`flaky` fails at both runs, and a second test fails only under an environment variable the
`baseline-head` run sets. `build-fail` adds a failure no test result holds. `vitest/unhandled`,
`vitest/pnpm-head`, `jest/pnpm-head`, `maven/multi-module-build-fail` and `ruby/suite-hook-fail` are extra
runs.

Captured 2026-10-04 on macOS 26 (arm64). Tools went into scratch only, with `MISE_DATA_DIR` and
every cache under `$SCRATCH` (mise 2025.12.7):

- Python 3.12.12 with pytest 9.1.1 in a uv venv.
- node 22.23.3 with npm 10.9.9; node 24.21.0 with pnpm 12.0.0 for the pnpm runs; vitest 5.0.3,
  jest 30.5.2 and jest-junit 17.0.0.
- Temurin JDK 21.0.12, Gradle 9.8.0, Maven 3.10.0, JUnit Jupiter 5.13.4 and Surefire 3.5.4.
- Ruby 3.4.11 (mise compiled it), Bundler 2.6.9, rspec-core 3.13.6, rspec_junit_formatter 0.6.0.
- Apple Swift 6.2 (swiftlang-6.2.3.3.20), and rustup with cargo 1.90.0.

`$CAP2`, `$SCRATCH/cap2.sh`, runs a command as the area runner does: through `/bin/sh -c` with stderr folded
into stdout (so `stderr` is empty), and `{junit}` expanded, quoted, to a fresh path. A report file
becomes `junit.xml`, and a Swift Testing report beside it `junit-swift-testing.xml`. A directory of
reports becomes `junit/`. The script then scrubs with `scrub2.sh`, which is `scrub.sh` above with
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
  `beta/.../BetaTest.java` has `fresh()`, failing under `GRADLEBASE_FAIL_NEW`.
- `maven`: 1 `pom.xml` (`mavenbase`, release 21, JUnit Jupiter, Surefire 3.5.4); `AlphaTest` with
  `passes()` and `flaky()`, and `BetaTest.fresh()` failing under `MAVENBASE_FAIL_NEW`.
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
  failing under `CARGOBASE_FAIL_NEW`; `PATH=$CARGO_HOME/bin:$PATH RUSTUP_TOOLCHAIN=1.90.0`.

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

## Run view: validation rows

`RunView/qa-checks/` is a real `swiftgate qa run` sequence over a 5-row validation table, for the
run view's Validation tab, its reader and the report. The table names the plan and tasks of
`RunView/build-run-1/`, and its ledger is that run's, so a test seeds that plan state beside it:
`counter-core-reset-and-decrement-floor` and `counter-ui-reset-button` are `done`, and
`counter-ui-reset-button-snapshot` is `abandoned`. Captured 2026-10-04 from a `swiftgate` debug
build of this commit's sources, in a `mktemp -d` copy of `examples/SampleApp`, whose
`.swiftgate.toml` loads, so telemetry writes the `qa` stream. From `plugin/gate` after
`swift build`, with `<harness>` this checkout:

```sh
SG=$PWD/.build/debug/swiftgate F=$PWD/Tests/Fixtures/RunView/build-run-1
T=$(mktemp -d) && cd $T && export LLVM_PROFILE_FILE=$T/p-%p.profraw GIT_CONFIG_GLOBAL=/dev/null
rsync -a --exclude .build --exclude .harness --exclude DerivedData <harness>/examples/SampleApp/ app/ && cd app
git init -q -b main
git add -A && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m base
SLUG=2026-10-03-counter-reset-and-floor P=.git/swift-harness/plans/$SLUG
mkdir -p $P && cp $F/ledger.json $P/ledger.json
cp <fixtures>/RunView/qa-checks/validation.json $P/validation.json
printf 'echo "count file missing" >&2\nexit 1\n' > $P/floor.state.sh
printf 'echo "count is 0"\n' > $P/reset.state.sh
$SG qa run --at-base      # exit 1, RED: 1 pass, 3 red, 1 unverified
sleep 1; $SG qa run       # exit 1, RED: 1 pass, 1 red, 2 unverified, 1 waiting
sleep 1; $SG qa run --after counter-core-reset-and-decrement-floor   # exit 0, GREEN: 1 pass, 1 waiting
cp .harness/events/qa.jsonl <fixtures>/RunView/qa-checks/events/qa.jsonl
for r in .harness/runs/*/; do mkdir -p <fixtures>/RunView/qa-checks/runs/$(basename $r); cp -R $r/qa <fixtures>/RunView/qa-checks/runs/$(basename $r)/; done
```

`validation.json` is the capture's hand-written input, shaped the way a plan's validation task
writes it; everything else is `qa run`'s output, unedited. Row 1's check, `/bin/test -d .git`,
starts with `/`, so the run view's payload guard rejects it; it fails at the merge base, where
`.git` is a file. Row 2 always exits 1, so its saved output carries the failure. Row 3 is a flow
row, which reads `unverified` until the flow runner exists. Row 4 runs after the abandoned task, so
it reads `waiting` on it. Row 5 reads `unverified` behind row 2. The copy leaves out each run's
`events/qa.jsonl`, which repeats its lines of the main stream.
`grep -rniE '/Users|/private|/var/folders|/tmp|caleb|@[a-z]+\.|swift-harness|home' RunView/qa-checks`
matched nothing.

## Run view: flow rows and kept flows

`RunView/qa-flows/` is a real `swiftgate qa run --final` over a 3-row validation table, then a real
`swiftgate test --tier t3` in the same checkout, for the run view's flow steps, kept flows and
timeline ticks. The table names the plan and tasks of `RunView/build-run-1/`, as
`RunView/qa-checks/` does. Captured 2026-10-04 with `agent-device` 0.21.18 and Xcode 26.2, from a
`swiftgate` debug build of this commit's sources, in a `mktemp -d` copy of `examples/SampleApp`;
`qa run` and T3 each ran on a clone the harness made under its `sim` lock. From `plugin/gate` after
`swift build --product swiftgate`, with `<harness>` this checkout and `<inputs>` a folder holding
the 4 input files below:

```sh
SG=$PWD/.build/debug/swiftgate H=<harness> IN=<inputs> F=$H/plugin/gate/Tests/Fixtures/RunView/build-run-1
T=$(mktemp -d) && export LLVM_PROFILE_FILE=$T/p-%p.profraw GIT_CONFIG_GLOBAL=/dev/null SWIFTGATE_HARNESS_ROOT=$H/plugin
rsync -a --exclude .build --exclude .harness --exclude DerivedData $H/examples/SampleApp/ $T/app/ && cd $T/app
git init -q -b main
git add -A && git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m base
SLUG=2026-10-03-counter-reset-and-floor P=.git/swift-harness/plans/$SLUG
mkdir -p $P && cp $F/ledger.json $P/ledger.json
cp $IN/validation.json $IN/counter.flow.json $IN/wrong-count.flow.json $IN/counter.state.sh $P/
$SG qa run --final              # exit 1, RED: 2 pass, 1 red
$SG test --tier t3 --json       # exit 0, GREEN: 2 UI tests, both mapped to the counter flow
Q=20261004T220955Z-1614d1ea G=20261004T221830Z-84cb5ca2 X=<fixtures>/RunView/qa-flows
mkdir -p $X/events $X/runs/$Q/qa $X/runs/$G
cp .harness/events/qa.jsonl .harness/events/gate.jsonl $X/events/
cp .harness/runs/$Q/qa/report.json .harness/runs/$Q/qa/02-*.state.txt $X/runs/$Q/qa/
for d in .harness/runs/$Q/qa/*.flow; do mkdir -p $X/runs/$Q/qa/$(basename $d); cp $d/flow.json $X/runs/$Q/qa/$(basename $d)/; done
for d in .harness/runs/$G/qa/xcuitest/*; do mkdir -p $X/runs/$G/qa/xcuitest/$(basename $d); cp $d/flow.json $X/runs/$G/qa/xcuitest/$(basename $d)/; done
cp .harness/runs/$G/report.json $X/runs/$G/report.json
```

The inputs are hand-written, shaped the way a plan's validation task writes them. `validation.json`
holds a flow row running `counter.flow.json`, a state row of the same requirement, and a flow row
running `wrong-count.flow.json`. `counter.flow.json` is `QA/counter.flow.json`, and
`wrong-count.flow.json` is the same flow expecting `5`, made with
`sed 's/"value":"1"/"value":"5"/'`. `counter.state.sh` is
`test -n "$QA_SIM_UDID" && echo "device $QA_SIM_BUNDLE_ID is up"`.

```json
{"schemaVersion":1,"unitOnly":[],"rows":[
{"requirement":"slice-1-reset-after-increments-shows-zero","layer":"flow","check":"counter.flow.json","runsAfter":["counter-ui-reset-button"],"writer":"counter-ui-reset-button"},
{"requirement":"slice-1-reset-after-increments-shows-zero","layer":"state","check":"counter.state.sh","runsAfter":["counter-ui-reset-button"],"writer":"counter-ui-reset-button"},
{"requirement":"slice-2-decrement-at-zero-stays-zero","layer":"flow","check":"wrong-count.flow.json","runsAfter":["counter-core-reset-and-decrement-floor"],"writer":"counter-core-reset-and-decrement-floor"}
]}
```

Everything copied is the commands' output, unedited. The qa stream holds 3 `qa.check` events, 2
batch `qa.flow` events with video, sheet and steps, row 3's last step not ok, and T3's 2 kept
`qa.flow` events, each a child of T3's `gate.run` in `events/gate.jsonl`. The copy leaves out each
run's MP4s, PNGs, `sim/`, `logs` and `container` folders and its own `events/` copies; tests that
serve a video write their own bytes. Row 1's `qa.check` lasts 356 s: the flow waited for the `sim`
lock under load. `grep -rniE '/Users|/private|/var/folders|/tmp|caleb|@[a-z]+\.|swift-harness|home' RunView/qa-flows`
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

## qa run: a validation table no row of which verified

`QA/aidoku-validation/` holds what the iOS validation trial on `Aidoku/Aidoku` left
(`evals/results/2026-10-04-brownfield-ios-validation/`, findings 3, 4 and 12). `validation.json`
is the plan's table: 2 flow rows and 1 state row behind the second. `at-base-report.json` is
`qa run --at-base`'s report, whose state row ran with no device and read red on a missing
`QA_SIM_UDID`, and `final-report.json` is the `final` `qa run`'s, 3 of 3 rows `unverified` and
GREEN. `after-report.json` is `qa run --after download-prompt`'s, with no row to run. From the
repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation F=plugin/gate/Tests/Fixtures/QA/aidoku-validation
mkdir -p $F && cp $S/validation.json $F/validation.json
sed -E 's#/Users/[^/]*/Developer/trials/#/TRIALS/#g' $S/qa-runs/20261004T211326Z-e21553f8/report.json > $F/at-base-report.json
sed -E 's#/Users/[^/]*/Developer/trials/#/TRIALS/#g' $S/qa-runs/20261004T213430Z-5250c2ac/report.json > $F/final-report.json
cp $S/qa-runs/20261004T213311Z-fea5f318/report.json $F/after-report.json
```

The `sed` replaces the trial clone's parent folder in each `sim up` message with `/TRIALS/` and
changes nothing else. `grep -rniE '/Users|/private|/var/folders|caleb' QA/aidoku-validation`
matched nothing.

## qa run: a state row behind another requirement's red flow

`QA/aidoku-validation-2/` holds what the iOS validation trial's second attempt on `Aidoku/Aidoku`
left (`evals/results/2026-10-04-brownfield-ios-validation-2/`, finding 3). `validation.json` is
the plan's table: a flow row for `req-setting`, then a flow row and a state row for `req-stored`.
`after-report.json` is `qa run --after download-setting`'s report: row 1 red, row 2 unverified,
and row 3 unverified behind row 1. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-2 F=plugin/gate/Tests/Fixtures/QA/aidoku-validation-2
mkdir -p $F && cp $S/validation.json $F/validation.json
cp $S/qa-runs/20261004T222811Z-0be8aeb0/report.json $F/after-report.json
```

`grep -rniE '/Users|/private|/var/folders|caleb' QA/aidoku-validation-2` matched nothing.

## qa run: rows still waiting once the build ended

`QA/aidoku-validation-3/` holds what the iOS validation trial's third attempt on `Aidoku/Aidoku`
left (`evals/results/2026-10-04-brownfield-ios-validation-3/`, finding 1). `validation.json` is the
plan's table: 2 flow rows and a state row after `confirm-downloads-setting`, and an acceptance row
after `confirm-downloads-check`. `ledger.json` is the plan's ledger at the end, with
`confirm-downloads-setting` `abandoned`. `build-events.jsonl` is the build run's
`events.jsonl`: that task's merge, its GREEN merge gate, then the `final` gate.
`final-report.json` is the plain `qa run` after `final`: 3 rows `waiting` and GREEN. From the
repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-3 F=plugin/gate/Tests/Fixtures/QA/aidoku-validation-3
mkdir -p $F && cp $S/validation.json $F/validation.json
sed -E 's#/Users/[^/]*/Developer/trials/#/TRIALS/#g' $S/ledger.json > $F/ledger.json
cp $S/build-events.jsonl $F/build-events.jsonl
cp $S/qa-runs/20261005T002359Z-7b81c6a7/qa/report.json $F/final-report.json
```

The `sed` replaces the trial clone's parent folder in each task's `worktree` with `/TRIALS/` and
changes nothing else. `grep -rniE '/Users|/private|/var/folders|caleb' QA/aidoku-validation-3`
matched nothing.

`at-base-report.json` is the orchestrator's `qa run --at-base` in that trial, after `qa adopt`: all
4 rows red at `c1766cda`, the 2 flows on a device. `store.state.sh` is the state row's script the
validation worker wrote. With `S` and `F` as above:

```sh
cp $S/qa-runs/20261004T235239Z-4acebe48/qa/report.json $F/at-base-report.json
cp $S/qa/confirm-large-downloads-store.state.sh $F/store.state.sh
```

The same `grep` on both files matched nothing.

## Run view: a RED gate's report

`RunView/build-run-1/runs/20261004T050310Z-ed998508/report.json` is the `report.json` the merge
gate of `counter-ui-reset-button` wrote in the `build-run-1` capture (see its `SOURCE`), the run
that went RED on the `counterWithFact` snapshot test before the fixer turned the task GREEN. The
run viewer reads it for that gate's failure: its tier, gating findings and failing test. The
capture's scratch repository still held it on 2026-10-04; with `S` that scratch directory and
`R=20261004T050310Z-ed998508`, this copy made 2 path substitutions and nothing else:

```sh
sed -e 's#/var/folders/lb/9c21kv5n74x2gyjdxqn51ngh0000gn/T/tmp\.IvRTQZud90#/var/folders/xx/T/tmp.scratch#g' \
    -e 's#/Users/<user>/#/Users/user/#g' \
    $S/app/.harness/runs/$R/report.json > <fixtures>/RunView/build-run-1/runs/$R/report.json
```

The `t2.test-failed` finding's message is the snapshot library's own, 13 lines long with 2
`file://` URLs: 1 under the checkout and 1 under the simulator's data directory. The substitutions
keep both absolute, so a test can show that neither reaches a run view: the builder makes the
first repo-relative from the checkout root and replaces the second with `<path>`. Those 2 URLs are
the only matches of the run view greps above in this file.

## Run view: a brownfield run with blocked tasks

`RunView/brownfield-blocked/` is the state a real brownfield run left, for the run view's worker
gate runs in a clone's shared store and its blocked tasks. The `memos-3` trial ran the run skill
on a clone of the `usememos/memos` repository on 2026-10-04, build run
`20261004T124141Z-c3747b7a` of plan `spec`. The contract task finished. `share-view-limit-store`
and `share-view-limit-web` ran in parallel. Each worker's slice gate went RED once in its own
worktree (`neutral.lint` on `store/test/memo_share_test.go:212`, and the web area's lint), then
GREEN. Each task ended `blocked` when `build check-return` rejected its return for an
`app-build` step a slice gate never records. That rejection is in no event or ledger line: the
run's `REPORT.md` holds it as prose. `share-view-limit-api` never started.

With `G` the clone's `.git`, `C=$G/swift-harness`, `P=$C/plans/spec` and
`R=$P/build/20261004T124141Z-c3747b7a`, copied after the run ended:

```sh
S='s#/Users/<user>/Developer/trials/memos-3-#../memos-3-#g; s#"/private/tmp/[^"]*/spec\.md"#"/spec.md"#g; s#"/Users/<user>/Developer/trials/memos-3/\.git/swift-harness/plans/spec/spec\.md"#"/spec.md"#g'
cp $C/events/{gate,span,build,brownfield,usage}.jsonl $C/events/store.json events/
sed -E "$S" $P/ledger.json > ledger.json; sed -E "$S" $P/clock.json > clock.json; cp $P/plan.json plan.json
cp $R/events.jsonl ledger-events.jsonl; cp $R/run.json run.json; cp $R/returns/*.json returns/
for w in $G/worktrees/*; do n=$(basename $w); for r in $w/swift-harness/runs/2*/; do
  mkdir -p worktrees/$n/runs/$(basename $r); cp $r/report.json worktrees/$n/runs/$(basename $r)/; done; done
```

The `sed` made the ledger's 4 worktree paths relative (`../memos-3-spec-<task>`), as
`build-run-1`'s are, and set `clock.json`'s `spec` and `origin` to `/spec.md`, as the reader
tests' clocks spell them. The hook stream, `PLAN.md`, `spec.md` and `REPORT.md` stayed out: the
reader reads none of them. `grep -rniE '/Users|/private|/var/folders|caleb|@[a-z]+\.|home'
RunView/brownfield-blocked` and the secrets grep above matched nothing; `/tmp` matches only a
repo-relative `.harness/tmp/edit.py` in an `agent.tools` file list.

`RunView/brownfield-blocked/{warmup,baseline}/98ce20b4568e17d2b5fee0f4a11ec054d03d03e2.json` are
the times file and the baseline file the same clone's warm-up wrote at its base tree, for the run
view's failure reason on a red warm-up step. The memos area's Go tests failed with 1 test id; the
web area's failed with no test id read, so its record holds the whole step. A later merge gate
added a second memos test record under a changed command to the baseline file. Copied 2026-10-04,
after the run ended, with `C` as above:

```sh
T=98ce20b4568e17d2b5fee0f4a11ec054d03d03e2
mkdir -p warmup baseline && cp $C/warmup/$T.json warmup/ && cp $C/baseline/$T.json baseline/
```

Both files are unedited copies; the grep above matched nothing in them.

`RunView/brownfield-rejected/` is the state the fourth brownfield trial on `usememos/memos` left
(`evals/results/2026-10-04-brownfield-trial/memos-4`), build run `20261004T141445Z-85d15f09` of plan
`spec`, plus 1 `build.return-checked` event. The web task's worker ran its `slice` GREEN in its own
worktree (`20261004T141801Z-79b9bebf`) and returned `surfaceCommit` as `"\"7c3becaa\""`, which
`build check-return` rejected, so the task ended `blocked`; the store task ended `blocked` on a design
conflict. That `check-return` recorded nothing then. The last line of `events/build.jsonl` is the event
this branch's `check-return` wrote for the same return file, re-run after the trial on a copy of the
clone, so its time is the capture's, not the run's.

With `T` the trial directory holding `memos-4` and its 3 worktrees `memos-4-spec`,
`memos-4-spec-share-view-limit-store` and `memos-4-spec-share-view-limit-web`, `X` a scratch directory,
and `SG` this branch's `swiftgate`, copied after the run ended:

```sh
cd $T && /bin/cp -c -R memos-4 memos-4-spec memos-4-spec-share-view-limit-store memos-4-spec-share-view-limit-web $X/
cd $X/memos-4 && git worktree repair $X/memos-4-spec $X/memos-4-spec-share-view-limit-store $X/memos-4-spec-share-view-limit-web
cd $X/memos-4-spec && $SG build check-return .harness/build/20261004T141445Z-85d15f09/share-view-limit-web.json --plan spec
G=$X/memos-4/.git C=$G/swift-harness P=$C/plans/spec R=$P/build/20261004T141445Z-85d15f09
S='s#/Users/[^/"]*/Developer/trials/memos-4-#../memos-4-#g; s#"/private/tmp/[^"]*/spec\.md"#"/spec.md"#g; s#"/Users/[^/"]*/Developer/trials/memos-4/\.git/swift-harness/plans/spec/spec\.md"#"/spec.md"#g'
cp $C/events/{gate,span,build,brownfield,usage}.jsonl $C/events/store.json events/
sed -E "$S" $P/ledger.json > ledger.json; sed -E "$S" $P/clock.json > clock.json; cp $P/plan.json plan.json
cp $R/events.jsonl ledger-events.jsonl; cp $R/run.json run.json; cp $R/returns/*.json returns/
for w in $G/worktrees/*; do n=$(basename $w); for r in $w/swift-harness/runs/2*/(N); do
  mkdir -p worktrees/$n/runs/$(basename $r); cp $r/report.json worktrees/$n/runs/$(basename $r)/; done; done
sed -i '' -E 's#"/Users/[^/"]*/Developer/trials/memos-4/#"<clone>/#g' worktrees/memos-4-spec/runs/20261004T141215Z-31ad3958/report.json
```

`check-return` printed `RED` with `build-return.surface-commit-off-branch`, as in the trial. The `git
worktree repair` pointed the copies at each other and left the trial's own checkouts as they were. The
last `sed` replaced the clone's absolute path in the GREEN merge gate's baseline finding. `grep -rniE
'/Users|/private|/var/folders|caleb|@[a-z]+\.|home|/tmp' RunView/brownfield-rejected` and the secrets grep
above matched nothing.

## Build returns: GREEN brownfield slice returns

`BuildReturn/memos-3/share-view-limit-{store,web}.json` are the 2 task returns the third brownfield trial on
`usememos/memos` handed to `build check-return`, which rejected both for a missing `app-build` step. Each
`.history.jsonl` beside it is the task worktree's `runs/history.jsonl` line for the `check slice` run the return
cites. The returns are the `result` of each `build-task` workflow's output file, written as the orchestrator wrote
them before calling `check-return`. `T` is the orchestrator session's task output directory,
`<Claude Code temp dir>/<cwd slug>/5f9bc272-d96a-48ac-ae63-61af01b8865a/tasks`, and `C` is the trial clone. From
this directory:

```sh
F=BuildReturn/memos-3 W=$C/.git/worktrees/memos-3-spec-share-view-limit
mkdir -p $F
for p in store:wj86fkhlk:20261004T124847Z-cc87cdd0 web:w2tnxl83w:20261004T124503Z-79e036f7; do
  IFS=: read task out run <<<"$p"
  python3 -c "import json,sys;d=json.load(open(sys.argv[1]));r=d['result'];sys.stdout.write(r if isinstance(r,str) else json.dumps(r))" \
    $T/$out.output > $F/share-view-limit-$task.json
  grep "\"runID\":\"$run\"" $W-$task/swift-harness/runs/history.jsonl > $F/share-view-limit-$task.history.jsonl
done
```

`grep -niE '/Users|/private|/var/folders|caleb' BuildReturn/memos-3/*` matched nothing.

## Build returns: a classified review that fell back to medium

`BuildReturn/memos-4/share-view-limit-{store,web}.json` are the 2 task returns the fourth brownfield trial on
`usememos/memos` got from its `build-task` workflows. The web return's `notes` end with the workflow's line
`review: classified at medium, because diff-risk gave no level (…)`, written when `judge diff-risk` found no
`[judge]` in the fresh clone; the store return is a `design-conflict` that stopped before review. Each is the
`result` of 1 line of the trial's committed `worker-journals.jsonl`, the 2 workflows' outputs. From this directory:

```sh
J=../../../../evals/results/2026-10-04-brownfield-trial/memos-4/worker-journals.jsonl
mkdir -p BuildReturn/memos-4
python3 -c "
import json,sys
for line in open(sys.argv[1]):
    r=json.loads(line)['result']
    r=r if isinstance(r,str) else json.dumps(r)
    open('BuildReturn/memos-4/'+json.loads(r)['task']+'.json','w').write(r)
" $J
```

`grep -niE '/Users|/private|/var/folders|caleb' BuildReturn/memos-4/*` matched nothing.

## Build returns: classified reviews diff-risk rated

`BuildReturn/memos-5/share-view-limit-{store,web,api}.json` are the 3 task returns the fifth brownfield trial on
`usememos/memos` got from its `build-task` workflows. Each return's `notes` end with the workflow's line
`review: classified at <level> by swiftgate judge diff-risk`: `high`, `medium` and `high`. Each is the `result` of
1 line of the trial's committed `worker-journals.jsonl`. From this directory:

```sh
J=../../../../evals/results/2026-10-04-brownfield-trial/memos-5/worker-journals.jsonl
mkdir -p BuildReturn/memos-5
python3 -c "
import json,sys
for line in open(sys.argv[1]):
    r=json.loads(line)['result']
    r=r if isinstance(r,str) else json.dumps(r)
    open('BuildReturn/memos-5/'+json.loads(r)['task']+'.json','w').write(r)
" $J
```

`grep -niE '/Users|/private|/var/folders|caleb' BuildReturn/memos-5/*` matched nothing.

### A stale task gate and a merge after a RED check

The rest of `BuildReturn/memos-5/` is state the fifth brownfield trial on `usememos/memos` left in its clone `C`, after the run
removed its task worktrees. The orchestrator wrote the 3 returns above byte for byte to its `returns/`, beside
`fix-share-view-limit-web.json`, the fixer's return `build check-return` read. `task-gate-runs.jsonl` is the `gate.run` event of
each run those returns cite, from the clone's gate event store: the store task's slice ran on a dirty tree at
the contract commit, not at the task's own commit. `last-commits.txt` is `git rev-parse` of each return's last
commit. `return-checked.jsonl` is the clone's 5 `build.return-checked` events, and `build-events.jsonl` is the
build run's event log, whose second web merge landed 1 s after the fixer's RED check. From this directory:

```sh
C=<trial clone>/.git/swift-harness B=$C/plans/spec/build/20261004T160656Z-0ad8c7c2 F=BuildReturn/memos-5
mkdir -p $F
cp $B/returns/fix-share-view-limit-web.json $F/
grep -E '"runID":"(20261004T160820Z-3c3ed983|20261004T160825Z-8924b00e|20261004T161750Z-62635ccf|20261004T161222Z-50cc3d46)"' \
  $C/events/gate.jsonl | grep '"kind":"gate.run"' > $F/task-gate-runs.jsonl
cp $C/events/build.jsonl $F/return-checked.jsonl
cp $B/events.jsonl $F/build-events.jsonl
for c in 990fd862 20e3afcf 0f470558 bae9f2f8; do echo "$c $(git -C $C/../.. rev-parse $c)"; done > $F/last-commits.txt
```

`grep -niE '/Users|/private|/var/folders|caleb' BuildReturn/memos-5/*` matched nothing.

## Brownfield trial: a contract landed before import

`BrownfieldTrial/` holds state the fourth brownfield trial on `usememos/memos` left, for a contract
the run commits and gates before `plan import`, and for the preset a first discovery writes.
`memos-4-PLAN.md` is the orchestrator's live plan, whose first task, `share-view-limit-contract`,
is the contract; `.swiftgate.toml`'s `prose_exclude` keeps the prose check off it. `memos-4-history.jsonl` is the plan checkout's and the web worktree's
`runs/history.jsonl`: the contract's `slice` at the base before the orchestrator committed it, a `doctor`, its
`merge` at the contract commit `6fc0cb61`, and the web task's `slice`. `memos-4-config.toml` is the
clone's `config.toml` after the orchestrator's `--set`s, with the `on_design_conflict = "block"` that
stopped the run. That trial had no RED gate run, so `memos-3-red-slice.history.jsonl` is the RED
`check slice` line of the third trial's store worktree. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-trial F=plugin/gate/Tests/Fixtures/BrownfieldTrial
mkdir -p $F
cp $S/memos-4/PLAN.md $F/memos-4-PLAN.md
cp $S/memos-4/gate-history-task-worktrees.jsonl $F/memos-4-history.jsonl
cp $S/memos-4/config.toml $F/memos-4-config.toml
grep '"runID":"20261004T124744Z-9d7ec113"' $S/memos-3/gate-history-task-worktrees.jsonl \
  > $F/memos-3-red-slice.history.jsonl
```

`grep -niE '/Users|/private|/var/folders|caleb' BrownfieldTrial/*` matched nothing.

## Claude Code plugin validation

`PluginValidate/` holds `claude plugin validate --strict --json plugin` reports from Claude Code
2.1.288, each with its exit status in a `.status` file. `unversioned-manifest` is this
repository's own plugin, whose manifest carries no `version` because `plugin-version.pinned`
forbids one. `unknown-field` is a temp copy of that manifest with a `"colour"` field added, so the
validator reports a second warning beside the version one. From the repository root:

```sh
ROOT=$(pwd -P) F=plugin/gate/Tests/Fixtures/PluginValidate
mkdir -p $F
{ claude plugin validate --strict --json plugin; echo $? > $F/unversioned-manifest.status; } \
  | sed "s#$ROOT#/REPO#g" > $F/unversioned-manifest.json
T=$(cd "$(mktemp -d)" && pwd -P)
mkdir -p $T/plugin && cp -R plugin/.claude-plugin $T/plugin/
sed -i '' 's#^  "license": "UNLICENSED"$#  "license": "UNLICENSED",\n  "colour": "blue"#' \
  $T/plugin/.claude-plugin/plugin.json
{ (cd $T && claude plugin validate --strict --json plugin); echo $? > $F/unknown-field.status; } \
  | sed "s#$T#/REPO#g" > $F/unknown-field.json
```

Observed behavior the check relies on: the version warning is the manifest entry's warning with
`path` `"version"`; `--strict` turns it into `"success": false` and exit status 1, and without
`--strict` it prints the same warning with `"success": true`. A manifest with a schema error
(such as `"keywords": "swift"`) reports the error and drops the version warning.
`grep -niE '/Users|/private|/var/folders|caleb' PluginValidate/*` matched nothing.

## Brownfield trial: a plan with a validation table

`BrownfieldTrial/memos-4-validation-PLAN.md` is `memos-4-PLAN.md` with a `## Validation` section
that Opus wrote for it, given that plan and `plugin/skills/run/references/plan-shape.md` as the
commit adding the fixture has it. The section went in before `## Assumptions`, and nothing else
changed. Opus gave every requirement an `acceptance` row, since the repository has no `xcode`
area. From the repository root, with Claude Code 2.1.288:

```sh
F=plugin/gate/Tests/Fixtures/BrownfieldTrial
{ printf 'Write the `## Validation` section of the brownfield PLAN.md below, following the reference that comes after it. The repository has 2 areas: `memos` (kind go) and `web` (kind node); it has no xcode area. Print only the section, starting with the `## Validation` heading, and nothing else.\n\n<plan>\n'
  cat $F/memos-4-PLAN.md
  printf '</plan>\n\n<reference>\n'
  cat plugin/skills/run/references/plan-shape.md
  printf '</reference>\n'; } > prompt.txt
(cd "$(mktemp -d)" && claude -p --model opus --tools "" < "$OLDPWD/prompt.txt") > section.md
python3 -c "
import sys
plan = open(sys.argv[1]).read(); section = open(sys.argv[2]).read()
i = plan.index('## Assumptions')
open(sys.argv[3], 'w').write(plan[:i] + section.rstrip('\\n') + '\\n\\n' + plan[i:])
" $F/memos-4-PLAN.md section.md $F/memos-4-validation-PLAN.md
```

`grep -niE '/Users|/private|/var/folders|caleb' BrownfieldTrial/memos-4-validation-PLAN.md`
matched nothing.

## Brownfield trial: an iOS clone's config

`BrownfieldTrial/aidoku-validation-config.toml` is the `config.toml` that `swiftgate discover
--apply` and the orchestrator's `--set`s wrote for the iOS validation trial on `Aidoku/Aidoku`: 1
`xcode` area with a project, a scheme, and a test command whose destination names the simulator.
`sim up` reads its target from that area. From the repository root:

```sh
cp evals/results/2026-10-04-brownfield-ios-validation/config.toml \
  plugin/gate/Tests/Fixtures/BrownfieldTrial/aidoku-validation-config.toml
```

`grep -niE '/Users|/private|/var/folders|caleb' BrownfieldTrial/aidoku-validation-config.toml`
matched nothing.

## Brownfield trial: a merge fixer looping on the merge gate

The third iOS validation trial on `Aidoku/Aidoku` sent 1 red merge to the fixer, which found each
of its test file's 3 faults by running `check --tier merge` again.
`BrownfieldTrial/aidoku-validation-3-fixer-gates.jsonl` holds each of its Bash calls that ran a
`check --tier`, in order, with the fix worktree as `/WORKTREE` and the harness's plugin as
`/PLUGIN`. `BrownfieldTrial/aidoku-validation-3-test-compile.tail.txt` is the output tail that the
red merge gate's `area.test-failed` finding quoted after `exit 65:`. It shows the new test file
that didn't compile, with the plan checkout as `/CLONE` and Xcode's DerivedData as `/DERIVED`. `W`
is the fix worktree, `P` the plugin, `C` the plan checkout and `D` the DerivedData directory the
trial ran with. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-3 F=plugin/gate/Tests/Fixtures/BrownfieldTrial \
  W=… P=… C=… D=… python3 - <<'PY'
import json, os
S, F, W, P, C, D = (os.environ[k] for k in ("S", "F", "W", "P", "C", "D"))
with open(f"{F}/aidoku-validation-3-fixer-gates.jsonl", "w") as out:
    for line in open(f"{S}/fixer.jsonl"):
        content = json.loads(line).get("message", {}).get("content")
        for c in content if isinstance(content, list) else []:
            if c.get("type") == "tool_use" and c["name"] == "Bash" and "check --tier" in c["input"]["command"]:
                command = c["input"]["command"].replace(W, "/WORKTREE").replace(P, "/PLUGIN")
                out.write(json.dumps({"command": command}) + "\n")
report = json.load(open(f"{S}/gates/merge-setting.json"))
message = next(x["message"] for x in report["findings"] if x["severity"] == "major")
tail = message.split("exit 65:\n", 1)[1].replace(C, "/CLONE").replace(D, "/DERIVED")
open(f"{F}/aidoku-validation-3-test-compile.tail.txt", "w").write(tail)
PY
```

`grep -niE '/Users|/private|/var/folders|caleb' BrownfieldTrial/aidoku-validation-3-*` matched
nothing.

## Brownfield trial: an iOS plan whose acceptance row names a source file

`BrownfieldTrial/aidoku-validation-2-PLAN.md` is the `PLAN.md` the orchestrator first wrote in
the second iOS validation trial on `Aidoku/Aidoku` (finding 2): its `req-check` acceptance row's
`Check` is the test file `AidokuTests/LargeDownloadConfirmationTests.swift`, which `plan import`
accepted and `qa run` then ran as a shell command. `Hooks/aidoku-validation-2-orchestrator-bash.json`
holds the 1 Bash call `guard.raw-xcodebuild` denied in that run: a `python3 - <<'EOF'` script that
only rewrote that row in `PLAN.md`, with the denial text. `H` is the harness checkout the trial
ran and `C` the clone. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-2 F=plugin/gate/Tests/Fixtures H=… C=… python3 - <<'PY'
import json, os
S, F, H, C = (os.environ[k] for k in ("S", "F", "H", "C"))
uses, denied, plan = {}, [], None
for line in open(f"{S}/run.jsonl"):
    entry = json.loads(line)
    content = (entry.get("message") or {}).get("content")
    if not isinstance(content, list): continue
    for block in content:
        if block.get("type") == "tool_use" and block.get("name") == "Bash":
            command = block["input"]["command"]
            uses[block["id"]] = command
            if plan is None and "| req-check | acceptance |" in command and command.startswith("cat <<'EOF' >"):
                plan = command.split("\n", 1)[1].rsplit("\nEOF", 1)[0] + "\n"
        if block.get("type") == "tool_result" and block.get("tool_use_id") in uses:
            text = block.get("content")
            text = text if isinstance(text, str) else json.dumps(text)
            if "guard.raw-xcodebuild" in text:
                denied.append({"command": uses[block["tool_use_id"]], "denial": text})
scrub = lambda s: s.replace(H, "/HARNESS").replace(C, "/CLONE")
open(f"{F}/Hooks/aidoku-validation-2-orchestrator-bash.json", "w").write(
    scrub(json.dumps(denied, indent=2, ensure_ascii=False) + "\n"))
open(f"{F}/BrownfieldTrial/aidoku-validation-2-PLAN.md", "w").write(scrub(plan))
PY
```

The plan is the heredoc's text, unchanged. `grep -niE '/Users|/private|/var/folders|caleb'` on
both files matched nothing.

## Brownfield trial: a UI plan with no flow row, finished on a RED qa run

The first tic-tac-toe trial ran `swiftgate run spec.md` on an iOS app starter with 1 `xcode`
area rooted at `.`. `BrownfieldTrial/tic-tac-toe-1-PLAN.md` is its `PLAN.md`: the
`ttt-screen` task writes `Packages/AppFeature/Sources/AppUI/` and `UITests/` and covers 3
requirements whose only rows are acceptance rows naming 1 XCUITest class, with no `flow` row
(finding 4). `tic-tac-toe-1-config.toml` is the clone's `config.toml`, and
`tic-tac-toe-1-plan.json` and `tic-tac-toe-1-validation.json` are what `plan import` wrote from
that plan. `tic-tac-toe-1-qa/<run>/qa/report.json` holds the 2 `qa run --plan spec` reports of
step 8, both RED and neither `--final`; the orchestrator ran `build finish` before it read the
second (finding 10). `S` is the trial folder, which kept the clone's plan state and each run's
`qa/` folder. From the repository root:

```sh
S=<trial folder> F=plugin/gate/Tests/Fixtures/BrownfieldTrial
mkdir -p $F/tic-tac-toe-1-qa
cp $S/PLAN.md $F/tic-tac-toe-1-PLAN.md
cp $S/config.toml $F/tic-tac-toe-1-config.toml
cp $S/plan.json $F/tic-tac-toe-1-plan.json
cp $S/validation.json $F/tic-tac-toe-1-validation.json
for r in 20261005T010144Z-9350394a 20261005T010428Z-75c783e4; do
  mkdir -p $F/tic-tac-toe-1-qa/$r/qa && cp $S/qa-runs/$r/report.json $F/tic-tac-toe-1-qa/$r/qa/
done
```

`grep -rniE '/Users|/private|/var/folders|caleb' BrownfieldTrial/tic-tac-toe-1-*` matched nothing.

## Brownfield trial: a flow row's sim run on an iOS clone

`BrownfieldTrial/aidoku-setting-flow/` is flow row 1 of the second iOS validation trial on
`Aidoku/Aidoku`, from its last `qa run` (`20261004T223404Z-be50ef8e`). `flow.json` is the flow file
the validation worker wrote. `sim/` holds that row's `session.json`, `steps.ndjson`, the 5
`snapshot --json` trees `sim snap` recorded, and the `report.json` `sim verify` wrote: RED on 183
findings, 103 `sim.a11y-identifier` and 80 `sim.a11y-label`, all but the new switch's on controls
the app already had. The screenshots stay out; no rule reads their bytes. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-2
R=$S/qa-runs/20261004T223404Z-be50ef8e/01-req-setting.flow
F=plugin/gate/Tests/Fixtures/BrownfieldTrial/aidoku-setting-flow
mkdir -p $F/sim/steps
cp $S/qa/confirm-large-downloads-toggle.flow.json $F/flow.json
cp $R/sim/session.json $R/sim/steps.ndjson $R/sim/report.json $F/sim/
cp $R/sim/steps/*.tree.json $F/sim/steps/
```

`grep -rniE '/Users|/private|/var/folders|caleb' BrownfieldTrial/aidoku-setting-flow` matched
nothing.

## Brownfield trial: the validation worker's Bash calls and flows on an iOS clone

`Hooks/aidoku-validation-3-worker-bash.json` holds every Bash command the validation worker ran in
the third iOS validation trial on `Aidoku/Aidoku`, in order. Calls 14 and 17 drive its prepared
flows with a raw `agent-device batch`. `BrownfieldTrial/aidoku-validation-3-config.toml` is that
clone's `config.toml` after the run, and `BrownfieldTrial/aidoku-validation-3-toggle.flow.json` and
`aidoku-validation-3-store.flow.json` are the 2 flows the worker wrote. `H` is the harness checkout
the trial ran and `C` the clone. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-3 F=plugin/gate/Tests/Fixtures H=… C=… python3 - <<'PY'
import json, os
S, F, H, C = (os.environ[k] for k in ("S", "F", "H", "C"))
commands = []
for line in open(f"{S}/validation-worker.jsonl"):
    entry = json.loads(line)
    content = (entry.get("message") or {}).get("content")
    if not isinstance(content, list): continue
    for block in content:
        if block.get("type") == "tool_use" and block.get("name") == "Bash":
            commands.append(block["input"]["command"])
scrub = lambda s: s.replace(H, "/HARNESS").replace(C, "/CLONE")
open(f"{F}/Hooks/aidoku-validation-3-worker-bash.json", "w").write(
    scrub(json.dumps(commands, indent=2, ensure_ascii=False) + "\n"))
PY
S=evals/results/2026-10-04-brownfield-ios-validation-3 F=plugin/gate/Tests/Fixtures/BrownfieldTrial
cp $S/config.toml $F/aidoku-validation-3-config.toml
cp $S/qa/confirm-large-downloads-toggle.flow.json $F/aidoku-validation-3-toggle.flow.json
cp $S/qa/confirm-large-downloads-store.flow.json $F/aidoku-validation-3-store.flow.json
```

`grep -niE '/Users|/private|/var/folders|caleb'` on the 4 files matched nothing.

## Node installs: 1 lockfile per package manager

`NodeInstall/<manager>/` holds a 1-dependency `package.json` and the lockfile its manager wrote installing it:
pnpm 10.25.0, npm 10.9.9, yarn 1.22.22 and bun 1.3.11, and `NodeInstall/yarn-berry/` the same project
installed by yarn 4.5.3. `NodeInstall/pnpm-outdated/` is the pnpm project with
the dependency moved to `6.0.0` and its lockfile left as it was; `output.txt` is what a frozen install printed
there, and it exited 1. Captured in an empty directory `S`:

```sh
for m in pnpm npm yarn bun; do mkdir -p $S/$m
  printf '{\n  "name": "install-fixture",\n  "version": "1.0.0",\n  "private": true,\n  "dependencies": {\n    "is-number": "7.0.0"\n  }\n}\n' > $S/$m/package.json
done
(cd $S/pnpm && pnpm install)
(cd $S/npm && npm install --no-audit --no-fund)
(cd $S/yarn && npx -y yarn@1.22.22 install)
(cd $S/bun && bun install)
mkdir -p $S/yarn-berry && cp $S/yarn/package.json $S/yarn-berry/
(cd $S/yarn-berry && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack yarn@4.5.3 install)
mkdir -p $S/pnpm-outdated && cp $S/pnpm/pnpm-lock.yaml $S/pnpm-outdated/
sed 's/"7.0.0"/"6.0.0"/' $S/pnpm/package.json > $S/pnpm-outdated/package.json
(cd $S/pnpm-outdated && CI=1 pnpm install --frozen-lockfile --prefer-offline > output.txt 2>&1)
for d in pnpm npm yarn yarn-berry bun pnpm-outdated; do mkdir -p NodeInstall/$d
  for f in package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lock output.txt; do
    [ -f $S/$d/$f ] && cp $S/$d/$f NodeInstall/$d/$f
  done
done
```

`grep -rniE '/Users|/private|/var/folders|caleb' NodeInstall` matched nothing.

## Brownfield trial: a cutoff after a task's merge gate

`BrownfieldTrial/aidoku-validation-3-build-events.jsonl` is the build run's `events.jsonl` from the
third iOS validation trial on `Aidoku/Aidoku`, and `aidoku-validation-3-cutoff.json` is the
`cutoff.json` `build cutoff` wrote in that run. The setting task merged, its first merge was undone
on a RED gate, the fixer's branch merged, and its GREEN merge gate was recorded in the same second
as the cutoff, which then set the task `abandoned`. From the repository root:

```sh
S=evals/results/2026-10-04-brownfield-ios-validation-3 F=plugin/gate/Tests/Fixtures/BrownfieldTrial
cp $S/build-events.jsonl $F/aidoku-validation-3-build-events.jsonl
cp $S/cutoff.json $F/aidoku-validation-3-cutoff.json
```

`grep -niE '/Users|/private|/var/folders|caleb' BrownfieldTrial/aidoku-validation-3-*` matched
nothing.

## QA: a test runner the busy shared simulator refused to launch

`QA/runner-launch/` and `Xcresult/runner-busy.*` come from a brownfield trial whose `test:`
acceptance rows ran `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'` on the
shared device while other sessions launched on it. `busy-1.tail.txt` and `busy-2.tail.txt` are the
ends of 2 rows' saved output (`qa/<row>.acceptance.txt`, stdout then stderr) from 2 `qa run`s, each
exit 65 with "Failed to install or launch the test runner … Busy (\"Application failed preflight
checks\")". `passed.tail.txt` is the end of a passing row's output from the same run as `busy-1`.
`Xcresult/runner-busy.{tests,build-results}.json` are read from `busy-1`'s result bundle, and
`runner-busy.status` is that run's exit status. From `plugin/gate/Tests/Fixtures`, with `S` the
trial folder and `APP`, `CLASS`, `REQ` the app's name, its UI test class and the busy row's
requirement:

```sh
SCRUB="s#$S/#/TRIAL/#g; s#/Users/[^/]*/#/HOME/#g; s#$APP#App#g; s#$CLASS#MainFlowUITests#g; s#$REQ#req-reset#g"
tailfrom() { a=$(grep -n "$2" "$1" | head -1 | cut -d: -f1); sed -n "$a,\$p" "$1" | sed -E "$SCRUB"; }
mkdir -p QA/runner-launch
tailfrom $S/qa-runs/<busy-1 run>/<row>.acceptance.txt '^\*\*\* If you believe' > QA/runner-launch/busy-1.tail.txt
tailfrom $S/qa-runs/<busy-2 run>/<row>.acceptance.txt '^\*\*\* If you believe' > QA/runner-launch/busy-2.tail.txt
tailfrom $S/qa-runs/<busy-1 run>/<passing row>.acceptance.txt '^Test session results' > QA/runner-launch/passed.tail.txt
B=$S/repo/.harness/runs/<busy-1 run>/qa/<row>.acceptance.xcresult
xcrun xcresulttool get test-results tests --path $B | sed -E "$SCRUB" > Xcresult/runner-busy.tests.json
xcrun xcresulttool get build-results --path $B | sed -E "$SCRUB" > Xcresult/runner-busy.build-results.json
echo 65 > Xcresult/runner-busy.status
```

The `sed` replaces the trial folder with `/TRIAL/`, the home folder with `/HOME/`, and the app,
class and requirement names, and changes nothing else. The result bundle's only failing case is
the runner's own "encountered an error", whose message is the launch failure.
`grep -rniE '/Users|/private|/var/folders|caleb' QA/runner-launch Xcresult/runner-busy.*` matched
nothing.

## Brownfield trial: a clone that commits its own config

`BrownfieldTrial/starter-swiftgate.toml` is the `.swiftgate.toml` the interview starter commits. A
brownfield one-shot trial ran `swiftgate run spec.md` on a fresh copy of the starter, and its
discovery wrote the common dir's `config.toml` beside this committed file, so every command in the
user's checkout failed on the 2 configs. The copy in that trial's repository matched this file byte
for byte. From the repository root:

```sh
cp evals/apps/interview-starter/.swiftgate.toml \
  plugin/gate/Tests/Fixtures/BrownfieldTrial/starter-swiftgate.toml
```

`grep -niE '/Users|/private|/var/folders|caleb' BrownfieldTrial/starter-swiftgate.toml` matched
nothing.
