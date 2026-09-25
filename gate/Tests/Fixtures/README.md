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
