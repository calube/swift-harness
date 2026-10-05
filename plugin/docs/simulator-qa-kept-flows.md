# Simulator QA kept flows

This page covers how T3 turns each kept XCUITest flow into a `qa.flow` record with its video and
contact sheet. A kept flow is a UI test that maps to a `[[flows]]` entry. Read it when you look
for a UI test's video, or when T3 reports a `qa.video-unverified` or `qa.evidence-unsaved` nit.

Batch flows and the final pass are in [`simulator-qa-flows.md`](simulator-qa-flows.md), and T3
itself in [`testing-playbook.md`](testing-playbook.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## What T3 records

After T3 reads its result bundle, each kept flow that ran becomes 1
record, failing tests included. A BLOCKED T3 run records none.

1. `xcresulttool get test-results activities --test-id <Class>/<method>()` gives the steps: the
   top-level activities of the test's last run, in order.
   - T3 leaves out XCTest's own `Start Test at …`, `Set Up` and `Tear Down` unless XCTest files a
     failure under one.
   - The first activity with `isAssociatedWithFailure` is the last step, with `ok` false. A failed
     test that files no failure marks its last step not ok.
   - A label keeps its title's first line, up to 200 characters.
2. `xcresulttool export attachments --test-id …` gives the screen recording. A test plan keeps one
   for every test when it sets `uiTestingScreenshotsLifetime` to `keepAlways` and
   `preferredScreenCaptureFormat` to `screenRecording`. The attachment's timestamp is the video's
   first frame, and each `offsetMs` counts from it. With no recording, offsets count from the
   test's first activity.
3. `agent-device record contact-sheet` reads the video into a sheet.

Each kept flow writes `qa/xcuitest/<Class>-<method>/` in the run directory: `activities.json`,
`video.mp4`, `sheet.png`, and `flow.json`, the record.

The record is also 1 `qa.flow` event, a child of the run's `gate.run`:

- `source` is `xcuitest`;
- `plan`, `row` and `requirement` are absent, and `atBase` is false;
- `flow` and `test` name the `[[flows]]` entry and the test;
- `video` and `sheet` are paths relative to the run directory.

## What it never does

The record never changes T3's verdict: the test passes or fails in T3 alone. A missing video sets
`videoUnverified` to `noVideoAttachment`, and a failed sheet sets `sheetUnverified` to
`sheetFailed`. Each is a `qa.video-unverified` nit naming the test. Unreadable activities leave no
record and a `qa.evidence-unsaved` nit.
