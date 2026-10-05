# Confirm large chapter downloads

## Requirements

- req-setting-toggle: Settings → Downloads shows a "Confirm Large Downloads" toggle, off by default, beside the other download toggles, with the stable accessibility identifier `Downloads.confirmLargeDownloads` and a readable label
- req-stored-value: The toggle's value is stored in user defaults under `Downloads.confirmLargeDownloads`, registered with the other download settings, and switching it on in the UI writes `true` under that key
- req-download-check: `LargeDownloadConfirmation.needsConfirmation(chapterCount:defaults:)` returns true only when the setting is stored on in the given defaults and more than 50 chapters are requested, proven by `AidokuTests/LargeDownloadConfirmationTests` with a dedicated `UserDefaults` suite at 50 and 51 chapters
- req-prompt: A chapter-list download that needs confirmation asks "Download <n> chapters?" with Download and Cancel before queueing; Cancel queues nothing, and requests that need no confirmation queue as before

## Areas

- Aidoku (xcode, root `.`; warm test 46 s, build-only; lint dropped: swiftlint not installed)

## Assumptions

- The key is `Downloads.confirmLargeDownloads`, following the `Downloads.*` keys in `DownloadsSettings`, and the accessibility identifier is that key, set on every settings toggle by `SettingView`, since the repository has no accessibility-id module.
- "Readable label" means the localized title `CONFIRM_LARGE_DOWNLOADS` = "Confirm Large Downloads" in `en.lproj`; other languages fall back to English.
- "One entry point" is a static function on a new `LargeDownloadConfirmation` enum in `Aidoku/Core/Downloads/`, taking `UserDefaults` as a parameter; the threshold is a strict `> 50`.
- The spec's "1 test class" is written as a Swift Testing `struct`, the convention every file in `AidokuTests` follows; `-only-testing:AidokuTests/LargeDownloadConfirmationTests/<method>` runs it alone.
- "A download from a manga's chapter list" is the multi-select Download button in `MangaView`'s edit toolbar; the single-chapter context-menu download asks for 1 chapter and never needs confirmation, and the Library screen's "Download All" menu sits outside a manga's chapter list, so it is unchanged.
- `<n>` is the number of chapters that would be queued: the selection minus chapters already downloaded, downloading or queued.
- The prompt is checked before the existing Wi-Fi-only check, so Cancel never reaches it and Download continues exactly as today.
- req-prompt gets no flow row: driving it needs an installed source with more than 50 chapters and network access, which a clean simulator lacks; the decision's acceptance test and the prompt task's slice gate stand in.

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-setting-toggle | flow | `qa/confirm-large-downloads-toggle.flow.json` | confirm-downloads-setting | spec-validation | |
| req-stored-value | flow | `qa/confirm-large-downloads-store.flow.json` | confirm-downloads-setting | spec-validation | |
| req-stored-value | state | `qa/confirm-large-downloads-store.state.sh` | confirm-downloads-setting | spec-validation | |
| req-download-check | acceptance | `test: AidokuTests/LargeDownloadConfirmationTests` | confirm-downloads-check | confirm-downloads-check | |
| req-prompt | | | | | needs a source with over 50 chapters and network in the simulator; the req-download-check acceptance test covers the decision the prompt follows |

### confirm-downloads-contract
Declare the setting key, the decision entry point as a stub, the localized strings and the toggle identifier.
- Deps: none · Gate: slice · estLines: 60
- Why: requirements 1 to 4 share 1 key, 1 entry point and 2 strings, so every task builds against them.
- Scope:
  - `DownloadsSettings.confirmLargeDownloads` (`Downloads.confirmLargeDownloads`, default false) in its `keys`
  - `LargeDownloadConfirmation.threshold = 50` and `needsConfirmation(chapterCount:defaults:)` returning false
  - `CONFIRM_LARGE_DOWNLOADS` and `DOWNLOAD_N_CHAPTERS_CONFIRM` in `en.lproj/Localizable.strings`
- Acceptance:
  - the Aidoku area builds; slice is GREEN
- Out of scope:
  - the toggle row, the decision logic and the prompt
- Covers: req-stored-value
- Writes: Aidoku/Core/Settings/Downloads/DownloadsSettings.swift, Aidoku/Core/Downloads/LargeDownloadConfirmation.swift, Aidoku/App/Resources/Localization/en.lproj/Localizable.strings

### confirm-downloads-setting
Add the "Confirm Large Downloads" toggle to Settings → Downloads with a stable accessibility identifier.
- Deps: confirm-downloads-contract · Gate: slice · estLines: 20
- Why: requirements 1 and 2: the toggle sits with the download toggles and writes its key.
- Scope:
  - a `.toggle` entry in `Settings.downloadSettings` keyed by `AppSettings.downloads.confirmLargeDownloads.key`, titled `CONFIRM_LARGE_DOWNLOADS`, after the parallel downloads toggle
  - `SettingView` sets `.accessibilityIdentifier(setting.key)` on its toggle
- Acceptance:
  - a test that `Settings.downloadSettings` holds a toggle with the key fails first, then passes; slice is GREEN
- Out of scope:
  - the decision and the prompt
- Covers: req-setting-toggle, req-stored-value
- Writes: Aidoku/Features/Settings/Settings.swift, Aidoku/App/Common/Settings/SettingView.swift, AidokuTests/ConfirmLargeDownloadsSettingTests.swift
- Tests: AidokuTests/ConfirmLargeDownloadsSettingTests.swift

### confirm-downloads-check
Implement the large-download decision from the chapter count and the stored setting.
- Deps: confirm-downloads-contract · Gate: slice · estLines: 60
- Why: requirement 3: more than 50 chapters with the setting stored on needs confirmation; otherwise never.
- Scope:
  - `needsConfirmation` reads `confirmLargeDownloads.key` from the given defaults (missing reads false) and compares with `threshold`
- Acceptance:
  - `AidokuTests/LargeDownloadConfirmationTests` stores the setting under its real key in a dedicated `UserDefaults(suiteName:)` suite, removed after, and checks 50 and 51 chapters with the setting on, 51 with it off and 51 with it never stored; it fails against the stub first, then passes; slice is GREEN
- Out of scope:
  - the prompt UI
- Covers: req-download-check
- Writes: Aidoku/Core/Downloads/LargeDownloadConfirmation.swift, AidokuTests/LargeDownloadConfirmationTests.swift
- Tests: AidokuTests/LargeDownloadConfirmationTests.swift

### confirm-downloads-prompt
Ask "Download <n> chapters?" before queueing a multi-select chapter download that needs confirmation.
- Deps: confirm-downloads-contract · Gate: slice · estLines: 60
- Why: requirement 4: Download and Cancel before queueing; Cancel queues nothing; other requests queue as today.
- Scope:
  - the edit toolbar's Download button in `MangaView` computes the chapters to queue, calls `LargeDownloadConfirmation.needsConfirmation(chapterCount:defaults: .standard)`, and when true holds them in state and shows an alert titled with `DOWNLOAD_N_CHAPTERS_CONFIRM` and Download and Cancel buttons
  - Download runs the existing Wi-Fi check and queue path with the held chapters; Cancel clears them and queues nothing
  - extract the queue path into 1 helper so both branches share it
- Acceptance:
  - the Aidoku area builds and slice is GREEN; the decision is covered by confirm-downloads-check's test
- Out of scope:
  - the Library screen's Download All, the context-menu single download, the download queue
- Covers: req-prompt
- Writes: Aidoku/Features/Manga/MangaView.swift

### spec-validation
Write the toggle flows and the stored-value state check against the contract's names, and record why each fails now.
- Deps: confirm-downloads-contract · Gate: slice · estLines: 80
- Why: requirements 1 and 2 need checks in the running app that fail before the toggle merges and pass after.
- Scope:
  - `qa/confirm-large-downloads-toggle.flow.json`: open Settings → Downloads and find the switch `Downloads.confirmLargeDownloads` labelled "Confirm Large Downloads", off
  - `qa/confirm-large-downloads-store.flow.json`: switch it on
  - `qa/confirm-large-downloads-store.state.sh`: read the installed app's defaults and require `Downloads.confirmLargeDownloads` to be true
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-setting-toggle, req-stored-value
- Writes: .harness/qa/spec/
