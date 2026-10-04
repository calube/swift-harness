# Simulator QA kept flows

How T3 turns each kept XCUITest flow into a qa.flow record (simulator QA amendment §6, §7, §11.1,
decision 17). Batch flows and the final pass are in [`simulator-qa-flows.md`](simulator-qa-flows.md),
and T3 itself in [`testing-playbook.md`](testing-playbook.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## What T3 records

A kept flow is a UI test that maps to a `[[flows]]` entry. After T3 reads its result bundle, and
unless the run is `BLOCKED`, each kept flow that ran becomes 1 record, failing tests included:

1. `xcresulttool get test-results activities --test-id <Class>/<method>()` gives the steps: the top-level
   activities of the test's last run, in order. T3 leaves out XCTest's own `Start Test at …`, `Set
   Up` and `Tear Down` unless XCTest files a failure under one. The first activity with
   `isAssociatedWithFailure` is the last step, with `ok` false. A failed test that files no failure
   marks its last step not ok. A label keeps its title's first line, up to 200 characters.
2. `xcresulttool export attachments --test-id …` gives the screen recording, which a test plan with
   `uiTestingScreenshotsLifetime` set to `keepAlways` and `preferredScreenCaptureFormat` set to
   `screenRecording` keeps for every test. Its attachment timestamp is the video's first frame, and
   each `offsetMs` counts from it. With no recording, offsets count from the test's first activity.
3. `agent-device record contact-sheet` reads the video into a sheet.

Each kept flow writes `qa/xcuitest/<Class>-<method>/` in the run directory: `activities.json`,
`video.mp4`, `sheet.png` and `flow.json`, the record.

The record is also 1 qa.flow event, a child of the run's `gate.run`: `source` is `xcuitest`,
`plan`, `row` and `requirement` are absent, `atBase` is false, and `flow` and `test` name the
`[[flows]]` entry and the test. `video` and `sheet` are run-relative.

## What it never does

The record never changes T3's verdict: the test passes or fails in T3 alone (amendment §6.2). A
missing video sets `videoUnverified` to `noVideoAttachment`, and a failed sheet sets
`sheetUnverified` to `sheetFailed`. Each is a `qa.video-unverified` nit naming the test. Unreadable
activities leave no record and a `qa.evidence-unsaved` nit.
