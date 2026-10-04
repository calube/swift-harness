# Download queue summary

The download queue screen lists each queued chapter with its own progress bar, but nothing shows how far the
whole queue has come. Readers who queue a long series want one line that answers "how much is left".

## What to build

1. A summary of the download queue, computed from the queued downloads and the per-chapter progress the queue
   screen already tracks: the number of chapters, the pages downloaded, the pages in total, and the overall
   fraction done.
2. A chapter with no progress reported yet counts as 0 of 0 pages. The fraction is 0 when the page total is 0,
   and never more than 1: a chapter whose reported progress is above its total counts as its total.
3. The queue screen shows the summary as its first row, above the paused banner and the per-source sections,
   and only while the queue isn't empty. The row shows the chapter count and "X of Y pages", with a linear
   progress bar of the overall fraction. It updates as chapters progress, finish or are cancelled.
4. The summary row carries the accessibility identifier `download-queue-summary`.
5. Each chapter's own progress bar uses the same safe fraction, so a chapter whose total is 0 no longer
   divides by zero.
6. New user-facing strings go through `NSLocalizedString` with keys added to the English
   `Localizable.strings`; other locales may fall back to English. Reuse an existing key where one fits.

## Constraints

- The summary is a plain value type with no dependency on SwiftUI or the download manager, so a unit test can
  build it from plain values.
- Don't change how downloads are queued, stored or reported; this is a display change.
- Keep the queue screen's existing behaviour: swipe to cancel, pause and resume, and the toolbar menu.

## Tests

- A unit test in the app's existing test target, in Swift Testing like its other tests, covering: an empty
  queue (0 chapters, fraction 0); chapters with no progress yet; progress summed across chapters from more
  than 1 source; and a progress above its total clamped to the total.
- The app builds for the iOS Simulator and the app's test scheme passes.
