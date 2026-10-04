# Confirm large chapter downloads

## Requirements

- req-setting: Settings → Downloads shows a "Confirm Large Downloads" toggle, off by default, beside the other download toggles, with the stable accessibility identifier `settings.downloads.confirmLargeDownloads`
- req-stored: The toggle's value is stored in user defaults under `Downloads.confirmLargeDownloads`, registered with the other download settings, and switching it on in the UI writes `true` there
- req-check: `LargeDownloadConfirmation.isRequired(chapterCount:defaults:)` returns true only when the setting stored in the given defaults is on and more than 50 chapters are requested
- req-prompt: A chapter-list download from a manga's page that needs confirmation asks "Download <n> chapters?" with Download and Cancel before queueing, Cancel queues nothing, and other requests queue as today

## Areas

- Aidoku (warm test unknown: the warm-up has recorded no run yet; `slice` measures it)

## Assumptions

- Single touched area, so no explorers ran; the plan comes from the orchestrator's own reading of the code.
- The stored key is `Downloads.confirmLargeDownloads`, following the `Downloads.compress` / `Downloads.parallel` naming in `DownloadsSettings`.
- The accessibility identifier is `settings.downloads.confirmLargeDownloads`, declared as `LargeDownloadConfirmation.toggleAccessibilityIdentifier`, since the repository has no typed accessibility-id module; `SettingView` applies it to this toggle only so no other setting changes.
- The entry point is `LargeDownloadConfirmation.isRequired(chapterCount:defaults:)` in `Aidoku/Core/Downloads/`, reading the key straight from the `UserDefaults` it is handed rather than through `SettingsKey.get()`, which reads `UserDefaults.standard`.
- "A download from a manga's chapter list" means the 2 download actions in `MangaView`: the multi-select Download button and the per-chapter context menu. The library's "Download All" menu in `LibraryViewController` is not a chapter list and stays unchanged. The count is the number of chapters actually queued after the already-downloaded/queued filter.
- The prompt reuses the repository's `confirmationDialogOrAlert` helper and its `CANCEL` / `DOWNLOAD` strings; the title is a new `DOWNLOAD_N_CHAPTERS_CONFIRM` = "Download %i chapters?" string, added in English only, like recent string additions.
- The Wi-Fi-only check still runs before the confirmation; a confirmed download then queues exactly as an unconfirmed one does.
- req-prompt has no flow row: driving it needs an installed source with a manga of more than 50 chapters, which a fresh simulator doesn't have. req-check's acceptance test proves the decision, and review checks the `MangaView` wiring.

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-setting | flow | `qa/confirm-large-downloads-toggle.flow.json` | download-setting | spec-validation | |
| req-stored | flow | `qa/confirm-large-downloads-stored.flow.json` | download-setting | spec-validation | |
| req-stored | state | `qa/confirm-large-downloads-stored.state.sh` | download-setting | spec-validation | |
| req-check | acceptance | `AidokuTests/LargeDownloadConfirmationTests.swift` | download-check | download-check | |
| req-prompt | | | | | needs a source with more than 50 chapters on the simulator; req-check's acceptance test proves the decision and review checks the MangaView wiring |

### contract
Declare the setting key, the decision entry point as a stub, the accessibility identifier and the strings, with no behaviour change.
- Deps: none · Gate: slice · estLines: 40
- Why: requirements 1 to 4 all read the same key, entry point and names, so each task builds against 1 declared shape.
- Scope:
  - `DownloadsSettings.confirmLargeDownloads` key declaration (not yet in `keys`)
  - `LargeDownloadConfirmation` with `threshold`, `toggleAccessibilityIdentifier` and a stub `isRequired(chapterCount:defaults:)` returning false
  - English strings `CONFIRM_LARGE_DOWNLOADS` and `DOWNLOAD_N_CHAPTERS_CONFIRM`
- Acceptance:
  - the app builds; slice is GREEN
- Out of scope:
  - any visible or stored behaviour
- Covers: req-check
- Writes: Aidoku/Core/Downloads/LargeDownloadConfirmation.swift, Aidoku/Core/Settings/Downloads/DownloadsSettings.swift, Aidoku/App/Resources/Localization/en.lproj/Localizable.strings

### download-check
Implement the large-download decision against the user defaults it is handed.
- Deps: contract · Gate: slice · estLines: 70
- Why: requirement 3, "one entry point decides whether a chapter-list download request needs confirmation".
- Scope:
  - `isRequired(chapterCount:defaults:)` reads `AppSettings.downloads.confirmLargeDownloads.key` from `defaults`; true only when the stored value is true and `chapterCount > threshold` (50)
- Acceptance:
  - `AidokuTests/LargeDownloadConfirmationTests.swift` (Swift Testing, `@testable import Aidoku`) uses a dedicated `UserDefaults(suiteName:)` suite, removed after each test, storing the setting under its real key: on + 51 → true, on + 50 → false, off + 51 → false, never stored + 51 → false; it fails against the stub, then passes; slice is GREEN
- Out of scope:
  - the settings row, registration, the prompt
- Covers: req-check
- Writes: Aidoku/Core/Downloads/LargeDownloadConfirmation.swift, AidokuTests/LargeDownloadConfirmationTests.swift
- Tests: AidokuTests/LargeDownloadConfirmationTests.swift

### download-setting
Register the setting and show its toggle in Settings → Downloads with its accessibility identifier.
- Deps: contract · Gate: slice · estLines: 40
- Why: requirements 1 and 2, the "Confirm Large Downloads" toggle, off by default, stored under its own registered key.
- Scope:
  - add `confirmLargeDownloads` to `DownloadsSettings.keys` so `AppSettings.registerDefaults()` registers it with default false
  - add a `.toggle` row keyed `AppSettings.downloads.confirmLargeDownloads.key`, titled `NSLocalizedString("CONFIRM_LARGE_DOWNLOADS")`, to `Settings.downloadSettings`' base items, after the parallel downloads toggle
  - in `SettingView.toggleView`, set `.accessibilityIdentifier(LargeDownloadConfirmation.toggleAccessibilityIdentifier)` on the `Toggle` only when `setting.key` is that key, leaving every other toggle unchanged
- Acceptance:
  - a Swift Testing test in `AidokuTests/ConfirmLargeDownloadsSettingTests.swift` checks the key is in `AppSettings.downloads.keys` with default false and that `Settings.downloadSettings` holds a toggle row for the key; it fails first, then passes; slice is GREEN
- Out of scope:
  - the decision logic and the prompt
- Covers: req-setting, req-stored
- Writes: Aidoku/Core/Settings/Downloads/DownloadsSettings.swift, Aidoku/Features/Settings/Settings.swift, Aidoku/App/Common/Settings/SettingView.swift, AidokuTests/ConfirmLargeDownloadsSettingTests.swift
- Tests: AidokuTests/ConfirmLargeDownloadsSettingTests.swift

### download-prompt
Ask before queueing a large chapter-list download from a manga's page.
- Deps: contract · Gate: slice · estLines: 80
- Why: requirement 4, the "Download <n> chapters?" prompt with Download and Cancel before queueing.
- Scope:
  - in `MangaView`, route the multi-select Download button and the per-chapter context-menu download through 1 helper that, after the existing Wi-Fi check, calls `LargeDownloadConfirmation.isRequired(chapterCount:defaults: .standard)`; when true it stores the pending chapters and shows a `confirmationDialogOrAlert` titled `String(format: NSLocalizedString("DOWNLOAD_N_CHAPTERS_CONFIRM"), n)` with Cancel (`role: .cancel`, queues nothing, clears the pending chapters) and Download (queues them); otherwise it queues at once as today
- Acceptance:
  - the app builds and slice is GREEN; behaviour is covered by download-check's acceptance test, as the view has no unit-test seam
- Out of scope:
  - the library's Download All menu, the download queue, its storage or notifications
- Covers: req-prompt
- Writes: Aidoku/Features/Manga/MangaView.swift

### spec-validation
Write the flow and state checks against the contract's names, and record why each fails now.
- Deps: contract · Gate: slice · estLines: 80
- Why: requirements 1 and 2 need checks in the running app that fail before download-setting merges and pass after.
- Scope:
  - 1 file under `.harness/qa/spec/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-setting, req-stored
- Writes: .harness/qa/spec/
