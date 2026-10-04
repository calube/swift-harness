# Download queue summary

## Requirements

- req-summary-values: A download queue summary built from the queued chapters and their reported progress holds the chapter count, the pages downloaded, the pages in total and the overall fraction done
- req-summary-safe-fraction: A chapter with no reported progress counts as 0 of 0 pages, the fraction is 0 when the page total is 0, and a chapter whose progress exceeds its total counts as its total so the fraction never exceeds 1
- req-summary-row: The queue screen shows the summary as its first row, above the paused banner and the per-source sections, only while the queue isn't empty, with the chapter count, "X of Y pages" and a linear progress bar of the fraction, updating as chapters progress, finish or are cancelled
- req-summary-a11y-id: The summary row carries the accessibility identifier `download-queue-summary`
- req-chapter-safe-fraction: Each chapter's own progress bar uses the same safe fraction, so a chapter whose total is 0 no longer divides by zero
- req-localized-strings: New user-facing strings go through `NSLocalizedString` with keys added to the English `Localizable.strings`, reusing existing keys where one fits
- req-plain-value-type: The summary is a plain value type with no dependency on SwiftUI or the download manager
- req-display-only: Downloads are queued, stored and reported as before, and the queue screen keeps swipe to cancel, pause and resume, and the toolbar menu
- req-unit-tests: A Swift Testing unit test in AidokuTests covers an empty queue, chapters with no progress, progress summed across more than 1 source, and progress above its total clamped to the total

## Areas

- Aidoku (warm test 107 s, build-only)

## Assumptions

- The summary lives in `Aidoku/Core/Downloads/Models/DownloadQueueSummary.swift` beside the other download models, so the app target and `AidokuTests` (which imports `@testable Aidoku`) both reach it.
- The summary's initializer is generic over a `Hashable` chapter key and takes the same `(progress, total)` tuple dictionary the queue screen keeps, so a test builds it from strings and ints without `ChapterIdentifier` or `Download`.
- "More than 1 source" in the tests means chapters whose keys come from 2 sources, flattened in queue order; the summary itself doesn't group by source, because the row shows only totals.
- A chapter whose reported progress is negative counts as 0 pages; the spec is silent, and a negative page count can't be shown.
- The chapter count reuses the existing `%i_CHAPTERS` key ("%i Chapters"); "X of Y pages" gets a new key `%i_OF_%i_PAGES` = "%i of %i pages", since the existing `%i_OF_%i` lacks the word "pages". Other locales fall back to English.
- The per-chapter "X of Y" caption under each chapter's bar is left as it is; only its bar's fraction changes.
- The warm-up's `build` and `test` failed with "Plugin SwiftLintBuildToolPlugin must be enabled"; both commands now pass `-skipPackagePluginValidation` (as the nightly CI workflow does) and `CODE_SIGNING_ALLOWED=NO`.

### summary-contract
Declare `DownloadQueueSummary` with its initializers, `fraction` and the static safe-fraction function, with stub bodies.
- Deps: none · Gate: slice · estLines: 40
- Why: requirements 1, 2 and 5 share 1 type, which both the test task and the view task compile against.
- Scope:
  - `DownloadQueueSummary`, a `Sendable`, `Equatable` struct importing only Foundation, with stub bodies that return zero
- Acceptance:
  - the app builds; slice is GREEN
- Out of scope:
  - the summing and clamping logic, the view row
- Covers: req-plain-value-type
- Writes: Aidoku/Core/Downloads/Models/DownloadQueueSummary.swift

### summary-logic
Implement the summary's summing and safe fraction, test-first.
- Deps: summary-contract · Gate: slice · estLines: 110
- Why: spec items 1 and 2, and the spec's Tests section.
- Scope:
  - `init(chapters:progress:)` sums each chapter's progress and total, counting a missing entry as 0 of 0, a progress above its total as its total and a negative progress as 0
  - `fraction(progress:total:)` returns 0 when total is 0 or below, and clamps the result to 0...1
- Acceptance:
  - `AidokuTests/DownloadQueueSummaryTests.swift`, in Swift Testing, covers an empty queue (0 chapters, fraction 0), chapters with no progress yet, progress summed across chapters from 2 sources, progress above its total clamped to the total, and the static fraction for a total of 0; each fails against the stub first, then passes; slice is GREEN
- Out of scope:
  - any change to `DownloadQueueView`, `DownloadManager` or `Localizable.strings`
- Covers: req-summary-values, req-summary-safe-fraction, req-plain-value-type, req-unit-tests
- Writes: Aidoku/Core/Downloads/Models/DownloadQueueSummary.swift, AidokuTests/DownloadQueueSummaryTests.swift
- Tests: AidokuTests/DownloadQueueSummaryTests.swift

### summary-row
Show the summary as the queue screen's first row and use the safe fraction for each chapter's bar.
- Deps: summary-contract · Gate: slice · estLines: 60
- Why: spec items 3, 4, 5 and 6.
- Scope:
  - in `DownloadQueueView`, a computed `DownloadQueueSummary` built from `queue` flattened in order (each download's `chapterIdentifier`) and the `progress` dictionary
  - a first `Section`, above the paused banner, shown only while `queue` isn't empty: the chapter count via `String(format: NSLocalizedString("%i_CHAPTERS"), …)`, "X of Y pages" via a new `%i_OF_%i_PAGES` key, and `ProgressView(value: summary.fraction).progressViewStyle(.linear)`, with `.accessibilityIdentifier("download-queue-summary")`
  - each chapter's bar uses `DownloadQueueSummary.fraction(progress:total:)` in place of the raw division
  - the English `Localizable.strings` gains `"%i_OF_%i_PAGES" = "%i of %i pages";`
- Acceptance:
  - the app builds for the iOS Simulator and slice is GREEN; the row's logic is the summary, which summary-logic's tests cover, so this task adds no UI test
- Out of scope:
  - how downloads are queued, stored or reported; swipe to cancel, pause and resume and the toolbar menu stay as they are; other locales' strings files
- Covers: req-summary-row, req-summary-a11y-id, req-chapter-safe-fraction, req-localized-strings, req-display-only
- Writes: Aidoku/Features/Library/DownloadQueueView.swift, Aidoku/App/Resources/Localization/en.lproj/Localizable.strings
