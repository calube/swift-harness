# Brownfield trial repositories: proposal

The brownfield plan's trial runs `swiftgate run <spec.md>` once in each of 3 public repositories the code has never
seen (design §14, §17 decision 13). This page proposes 3 repositories and 2 alternates. The orchestrator picks, records
the pick in the plan's decisions table, and commits it. The trial task writes each `spec.md` from the change named
here.

Checked on 2026-10-03 with `gh api repos/<r>`, `gh api repos/<r>/languages`, `gh api repos/<r>/license` and the CI
workflow files at the pinned commit.

## Bar

Each candidate must be:

- public, under an OSI license;
- more than 1 language with at least 10% of bytes each;
- tested in CI, with tests that run without secrets or paid services;
- under 1 GB to clone;
- absent from the plan's "Fixture repositories" table.

Across the 3: at least 4 distinct ecosystems, at least 1 Swift area, and no language pair repeated.

## Proposed

| | `mozilla/glean` | `usememos/memos` | `koel/koel` |
|---|---|---|---|
| URL | https://github.com/mozilla/glean | https://github.com/usememos/memos | https://github.com/koel/koel |
| Commit | `57dbeb97eaeda669ba8af3a3bab077bc5036d6d7` (`main`) | `0d989707f82c33f74bb852edd8965ec88fcf041b` (`main`) | `9f9ca6bfdf3d9dbe73708c12f821c2eeca92c562` (`master`) |
| License | MPL-2.0 | MIT | MIT |
| Languages at 10% or more | Rust 60.9%, Kotlin 15.5%, Swift 10.3% (Python 9.1% below the bar) | Go 51.0%, TypeScript 48.1% | PHP 55.6%, TypeScript 26.0%, Vue 17.6% |
| Ecosystems | Cargo, Gradle (Android library), Xcode with SwiftPM, pip | Go modules, pnpm (`web/`) | Composer, pnpm |
| Repository size (`gh api`) | 21.8 MB | 44.8 MB | 29.1 MB |
| CI | GitHub Actions `test.yml`, CircleCI `config.yml` | `backend-tests.yml`, `frontend-tests.yml` | `test-backend-sqlite.yml`, `unit-frontend.yml`, `lint-backend.yml`, `lint-frontend.yml` |
| CI test commands | `cargo test --all` (CI uses `cargo nextest run --all --features sqlite`); `./gradlew :glean:testDebugUnitTest`; `make test-swift` (`bin/iosbuild test sdk`); `make test-python` | `go test ./store/... ./server/... ./internal/...` and the other packages, `DRIVER=sqlite`; `pnpm test` (`vitest run`) and `pnpm lint` in `web/` | `php artisan key:generate`, then `composer test` (`php artisan test --parallel`, SQLite); `pnpm exec vp test --run` |
| Lint commands | `cargo clippy`, `./gradlew lint ktlint detekt`, `swiftlint`, `ruff` | `golangci-lint`, `biome check` | `mago format --check`, `mago lint`, `phpstan analyse` |
| Secrets or services in tests | none | none for the sqlite driver; the store group's mysql and postgres drivers may want containers, so the trial runs it with `DRIVER=sqlite` | none on the SQLite workflow |
| Warm build estimate | Cargo cold 3 to 5 min, warm incremental under 30 s; Gradle cold 3 to 5 min, needs an Android SDK; Swift needs the Rust xcframework first, cold 5 to 8 min | `go build` cold about 1 min, warm seconds; `pnpm install` plus `vite build` about 1 min | no PHP build; `composer install` and `pnpm install` about 1 min each |
| Candidate change | Add an optional upper bound to the quantity metric: a value above it records an `invalid_value` error instead of the value. Rust core in `glean-core/src/metrics/quantity.rs`, the UniFFI surface, and tests in Rust, `QuantityMetricTypeTest.kt` and `QuantityMetricTypeTest.swift` | Add an optional expiry to memo shares, so a share link stops resolving after a set time: a store migration for each driver, the API field, a share-dialog option in `web/`, a Go store test and a vitest test | Record a skip when a song is skipped before a set share of its length, store the count on the `Interaction` model, expose it on the song resource and show it as a column in the song list: a PHPUnit feature test and a vitest component test |
| Why | A Rust core with Kotlin and Swift bindings: 3 compiled areas, one of them an Xcode project, and a change that crosses all 3 | A Go server with a TypeScript client; fast builds, so it measures the `slice` bar on a light stack | PHP, an ecosystem no fixture covers, with a TypeScript and Vue client; no compile step on the server side |

Coverage across the 3: Cargo, Gradle, Xcode with SwiftPM, Go modules, Composer and pnpm, 6 ecosystems. The Swift area
is glean's. Language pairs: Rust–Kotlin, Rust–Swift, Kotlin–Swift; Go–TypeScript; PHP–TypeScript, PHP–Vue,
TypeScript–Vue. None repeats. The 3 differ in shape: a multi-language SDK, a server with a web client, and a
framework web application.

## Alternates

| | `getsentry/sentry-cocoa` | `wagtail/wagtail` |
|---|---|---|
| URL | https://github.com/getsentry/sentry-cocoa | https://github.com/wagtail/wagtail |
| Commit | `af5f30061c38e26070f855f80a094be9dc083cdc` (`main`) | `ae4a16dee644638019dd508b448a5315000745f7` (`main`) |
| License | MIT | BSD-3-Clause |
| Languages at 10% or more | Swift 65.3%, Objective-C 22.3% | Python 76.9%, JavaScript 11.2% |
| Ecosystems | Xcode with SwiftPM | pip, npm |
| Repository size | 58.2 MB | 259.9 MB |
| CI | `test.yml` through `unit-test-common.yml` | `test.yml` |
| CI test commands | `make test-ios` (`scripts/sentry-xcodebuild.sh` on a booted simulator) | `python runtests.py` with `DATABASE_ENGINE=django.db.backends.sqlite3`; `npm run test:unit` (`jest`) |
| Lint commands | `swiftlint`, `swift-format`, `clang-format` | `ruff`, `eslint`, `stylelint`, `prettier --check`, `tsc --noEmit` |
| Secrets or services in tests | none for unit tests | none on SQLite; the postgres, mysql and elasticsearch jobs need services and stay out of the trial |
| Warm build estimate | `xcodebuild` cold 4 to 6 min; simulator unit tests run several minutes, so `slice` may fall back to build-only (§17 decision 10) | `pip install -e .[testing]` and `npm ci` 1 to 2 min each; webpack build about 1 min |
| Candidate change | Add an option that drops breadcrumbs whose category is in a configured list, on the options type and the breadcrumb path, with unit tests | Add a filter to the admin page listing for pages with unpublished changes, with a Django test and a jest test for its client widget |
| Replaces | glean, if its Android SDK or xcframework build can't run on the trial machine. The 3 then still hold 4 ecosystems and a Swift area | memos or koel, if either one's install fails. Its pairs (Python–JavaScript) repeat none of the others |

## Rejected while checking

| Repository | Why |
|---|---|
| `photoprism/photoprism` | license reads `NOASSERTION`; GitHub Actions has only CodeQL, so no CI test workflow to read |
| `signalapp/libsignal` | fits the bar (Rust 62.4%, Swift 10.8%), but its only qualifying pair, Rust–Swift, repeats glean's |
| `home-assistant/iOS`, `bitwarden/ios`, `Automattic/pocket-casts-ios` | Swift at 97% or more: 1 language |
| `getredash/redash` | its Python tests run in `docker compose` with Postgres and Redis |
| `HumanSignal/label-studio` | 2.9 GB repository |
| `filebrowser/filebrowser` | archived |
| `navidrome/navidrome` | fits the bar, but repeats memos' Go and JavaScript shape; kept as a further fallback for memos |

## Tools the trial machine lacks

On 2026-10-03 this machine had no `php`, `composer`, `go` or `cargo` on `PATH`; `pnpm`, `java` and `xcodegen` were
present. The trial installs them into scratch with `mise`, or uses each project's wrapper (`./gradlew`), as the plan's
risk table says.

## iOS trial

On 2026-10-04 the maintainer asked for 1 more trial, on an iOS app, to prove the Xcode path end to end. This trial
has its own bar: a public iOS app, not an SDK or library; an OSI license; an Xcode project or workspace, possibly
with SwiftPM packages; a simulator build with Xcode 26.2 and no signing or secrets; unit tests that run on the
simulator; a clone under about 500 MB; activity in the last year; and absent from the fixture repositories and the
rejected list above. A mid-size SwiftUI app with a test target was preferred. Each candidate was checked by cloning
it and running `xcodebuild -list` and a simulator build of its main scheme, stopping at the first that built and
tested cleanly.

| | `thunderbird/thunderbird-ios` | `weiran/Hackers` | `Aidoku/Aidoku` |
|---|---|---|---|
| URL | https://github.com/thunderbird/thunderbird-ios | https://github.com/weiran/Hackers | https://github.com/Aidoku/Aidoku |
| Commit checked | `6f023c9a8af66f6e232052295775b179f9e37ea2` | `9760ef5342a7f4ffa0d6ff22e6e6b2acd0dc7017` | `3091ef26e593d303e34afed70bc8c5997c105f80` (`main`, 2026-10-03), pinned |
| License | MPL-2.0 | MIT | GPL-3.0 |
| Repository size (`gh api`) | 10.3 MB | 186.9 MB | 5.7 MB |
| Shape | SwiftUI; a workspace with 1 project, 2 local packages and an `.xctestplan` | SwiftUI; 1 project and 7 local packages | SwiftUI and UIKit, 475 Swift files; 1 project with 14 SwiftPM dependencies, synchronized folders, 1 shared scheme `Aidoku` with the Swift Testing target `AidokuTests` |
| Result | `xcodebuild -list` fails: the `bolt-design-system` package needs Swift tools 6.3, and Xcode 26.2 has 6.2.1 | not built: every package is `swift-tools-version: 6.4`, `SWIFT_VERSION = 6.4`, and CI runs on Xcode 27 | builds and tests: a cold simulator build in 165 s, then 363 tests passed in 137 s, at a 1-minute load of about 770 to 990 |

Aidoku is the pick. Its build and test need `-skipPackagePluginValidation` (it uses the SwiftLint build-tool plugin)
and `CODE_SIGNING_ALLOWED=NO`, as its own CI passes; tests ran on a simulator created for the check and deleted
after it. Its CI builds a nightly archive and runs SwiftLint but runs no tests. The change for its `spec.md` is a
download queue summary: a value type in `Aidoku/Core/Downloads/Models/`, a first row in `DownloadQueueView` with an
accessibility identifier, the per-chapter bar's division by zero fixed, and a Swift Testing test. Results are in
[the trial's README](../../evals/results/2026-10-04-brownfield-trial/aidoku-ios-1/README.md).

Also screened by their tracked files, not built because Aidoku passed first: `mlemgroup/mlem` (GPL-3.0),
`openhab/openhab-ios` (EPL-2.0), `jellyfin/Swiftfin` (MPL-2.0; only its macro package has tests),
`Dimillian/IceCubesApp` (AGPL-3.0) and `Ranchero-Software/NetNewsWire` (MIT). `nalexn/clean-architecture-swiftui`
(MIT) fails the activity bar: it was last pushed on 2025-07-14.
