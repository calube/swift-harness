# Confirm large chapter downloads

## Requirements

- req-setting: Settings → Downloads shows a toggle titled "Confirm Large Downloads", off by default, among the other download toggles, with the accessibility identifier `Downloads.confirmLargeDownloads`
- req-stored: The toggle's value is stored in user defaults under `Downloads.confirmLargeDownloads`, registered with the other download settings, and switching it on writes `true` there
- req-threshold: `LargeDownloadConfirmation.needsConfirmation(chapterCount:isEnabled:)` returns true only when the setting is on and more than 50 chapters are requested, with unit tests in AidokuTests
- req-prompt: A download from a manga's chapter list that needs confirmation asks "Download <n> chapters?" with Download and Cancel before queueing; Cancel queues nothing, and other requests queue as today

## Areas

- Aidoku (xcode, root `.`; warm test time unknown, the warm-up failed before the plugin-validation fix, so slice measures it)

## Assumptions

- The warm-up build and test failed on "SwiftLintBuildToolPlugin must be enabled"; both commands now pass `-skipPackagePluginValidation`, the flag CI uses for unattended plugin builds.
- The manga chapter list's download paths are the multi-select toolbar Download button (which covers Select All, the screen's "Download All") and the per-chapter context-menu Download; the single-chapter path never crosses 50, so the prompt sits on the toolbar path. The library screen's Download All/Unread menu is another screen and stays out of scope.
- `<n>` in the prompt is the count of chapters that would actually be queued, after the existing filter drops downloaded, downloading and queued chapters.
- The prompt is shown before the existing Wi-Fi check; confirming then runs today's path unchanged, including the no-Wi-Fi alert.
- The defaults key is `Downloads.confirmLargeDownloads`, following the `Downloads.` prefix of the other download keys, and the accessibility identifier reuses that string.
- The toggle sits after "Parallel Downloads" and before the iOS 26 background toggle, inside the existing download settings group; only the English string is added, other locales fall back to the key's English text as the app does for new strings.
- The repository has no typed accessibility-id module, so the identifier lives as a constant on `LargeDownloadConfirmation`.
- settings-toggle's first merge went red on its own test (it read toggle keys from the top level of `Settings.downloadSettings`, which is 1 group); the fixer changed only the test to read the group's items, and the fix merge's gate was GREEN.
- download-prompt branched while that red merge was on the plan branch, so its return failed `build-return.outside-write-set` after the undo; halt answered retry: its 1 commit was rebased onto the plan branch and the task relaunched into its worktree to re-gate.
- The flow and state rows read `unverified`: `sim up` loads `.swiftgate.toml` from the tree, which a brownfield clone lacks, so no simulator could be leased; the rows stay, and the report quotes them.
- req-prompt gets no flow row: driving it needs an installed source with a manga over 50 chapters, which a fresh simulator lacks; the threshold unit tests and the merge build stand in for it.

### spec-contract
Declare the settings key, the threshold function stub, the identifier and the strings every task compiles against.
- Deps: none · Gate: slice · estLines: 30
- Why: requirements 1 to 4 share the key, the identifier and the function signature.
- Scope:
  - `DownloadsSettings.confirmLargeDownloads` registered in `keys`, default false
  - `LargeDownloadConfirmation` with `threshold`, `settingAccessibilityIdentifier` and a stub `needsConfirmation` returning false
  - English strings `CONFIRM_LARGE_DOWNLOADS` and `DOWNLOAD_%i_CHAPTERS_CONFIRM`
- Acceptance:
  - the app builds; slice is GREEN
- Out of scope:
  - the toggle row, the rule and the prompt
- Covers: req-stored
- Writes: Aidoku/Core/Settings/Downloads/DownloadsSettings.swift, Aidoku/Core/Downloads/LargeDownloadConfirmation.swift, Aidoku/App/Resources/Localization/en.lproj/Localizable.strings

### threshold-rule
Implement the pure threshold rule with unit tests.
- Deps: spec-contract · Gate: slice · estLines: 60
- Why: requirement 3, "with the setting on, more than 50 chapters needs confirmation; 50 or fewer, or the setting off, never does".
- Scope:
  - `LargeDownloadConfirmation.needsConfirmation(chapterCount:isEnabled:)` returns `isEnabled && chapterCount > threshold`
- Acceptance:
  - Swift Testing tests in `AidokuTests/LargeDownloadConfirmationTests.swift` for 51 on (true), 50 on (false), 0 on (false), 500 off (false) fail on the stub, then pass; slice is GREEN
- Out of scope:
  - reading the setting and any UI
- Covers: req-threshold
- Writes: Aidoku/Core/Downloads/LargeDownloadConfirmation.swift, AidokuTests/LargeDownloadConfirmationTests.swift
- Tests: AidokuTests/LargeDownloadConfirmationTests.swift

### settings-toggle
Show the "Confirm Large Downloads" toggle in Settings → Downloads with its accessibility identifier.
- Deps: spec-contract · Gate: slice · estLines: 50
- Why: requirements 1 and 2: the toggle, off by default, beside the other download toggles, writing its defaults key.
- Scope:
  - a `.toggle` entry in `Settings.downloadSettings` for `AppSettings.downloads.confirmLargeDownloads.key`, titled `NSLocalizedString("CONFIRM_LARGE_DOWNLOADS")`, after Parallel Downloads
  - the toggle carries the accessibility identifier `LargeDownloadConfirmation.settingAccessibilityIdentifier`; the least invasive way is `.accessibilityIdentifier(setting.key)` on the row's Toggle in `SettingView`, which gives every settings toggle its key as identifier and changes no behaviour
  - a unit test that `Settings.downloadSettings` lists the key as a toggle and that `AppSettings.downloads.keys` registers it with default false
- Acceptance:
  - `AidokuTests/ConfirmLargeDownloadsSettingTests.swift` fails before the entry exists, then passes; slice is GREEN
- Out of scope:
  - the prompt and any other setting's title or behaviour
- Covers: req-setting, req-stored
- Writes: Aidoku/Features/Settings/Settings.swift, Aidoku/App/Common/Settings/SettingView.swift, AidokuTests/ConfirmLargeDownloadsSettingTests.swift
- Tests: AidokuTests/ConfirmLargeDownloadsSettingTests.swift

### download-prompt
Ask before queueing a large chapter download from the manga's chapter list.
- Deps: threshold-rule · Gate: slice · estLines: 70
- Why: requirement 4, "the app asks 'Download <n> chapters?' with Download and Cancel actions before queueing anything; Cancel queues nothing".
- Scope:
  - in `MangaView`'s toolbar Download button, compute the chapters to queue as today, then if `LargeDownloadConfirmation.needsConfirmation(chapterCount:isEnabled: AppSettings.downloads.confirmLargeDownloads.get())` holds, store them and present an alert titled `String(format: NSLocalizedString("DOWNLOAD_%i_CHAPTERS_CONFIRM"), n)` with `CANCEL` (cancel role, queues nothing) and `DOWNLOAD` (runs today's Wi-Fi check and queue)
  - requests that don't need confirmation run today's code path unchanged
  - factor the queueing into 1 helper both branches call, so Download and the no-prompt path share it
- Acceptance:
  - the app builds and slice is GREEN; the threshold tests from threshold-rule pass at this task's base
- Out of scope:
  - the download queue, its storage and notifications; the library screen's download menu; the single-chapter context menu
- Covers: req-prompt
- Writes: Aidoku/Features/Manga/MangaView.swift

### spec-validation
Write the flow and state checks for the toggle against the contract's names, and record why each fails now.
- Deps: spec-contract · Gate: slice · estLines: 80
- Why: requirements 1 and 2 need checks in the running app that fail before settings-toggle merges and pass after.
- Scope:
  - 1 file under `.harness/qa/spec/` per `## Validation` row whose `Writer` is this task
- Acceptance:
  - `qa lint` is GREEN on each flow; `qa run --at-base` reads each row red
- Out of scope:
  - source, tests in the tracked tree, and any commit
- Covers: req-setting, req-stored
- Writes: .harness/qa/spec/

## Validation

| Done when | Layer | Check | Runs after | Writer | Reason |
|---|---|---|---|---|---|
| req-setting | flow | `qa/confirm-toggle.flow.json` | settings-toggle | spec-validation | |
| req-stored | flow | `qa/confirm-toggle-on.flow.json` | settings-toggle | spec-validation | |
| req-stored | state | `qa/confirm-toggle-on.state.sh` | settings-toggle | spec-validation | |
| req-threshold | | | | | the unit tests in threshold-rule cover every branch of the pure rule |
| req-prompt | | | | | needs an installed source with a manga over 50 chapters, which a fresh simulator lacks; the threshold tests and the merge build stand in |
