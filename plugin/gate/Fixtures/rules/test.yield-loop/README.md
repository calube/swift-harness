# `test.yield-loop` fixtures

`bad/SimFeatureTests.swift` is a real test file, captured from a practice trial's reducer task
(its last commit to the reducer's tests), with the app's domain words renamed. It tests a reducer
whose repeating timer effect starts on an input, and both of its timer tests wait for that effect
with `for _ in 0..<200 { await Task.yield() }` before advancing the `TestClock`. The worker added
the first loop after a tick-rate test failed and copied it into the retry of a stop test that
review had found could not fail; that retry then took 6 red test runs. From the trial clone, with
`<tests>` the test file's repository-relative path and `<rename>` a `perl` script of 27
substitutions that renames the app's domain words (its feature, state and layout types, actions,
statuses and display strings) to `Sim`, `layout`, `strip`, `inputChanged`, `restartTapped`,
`finished` and `count`, kept out of this repository so the fixture names no app:

```sh
git show ab0bdc2:<tests> | perl -p <rename> > bad/SimFeatureTests.swift
```

`good/RepeatingTimer.swift` is the testing playbook's repeating-timer recipe, from a scratch
package that ran it against the reducer and against mutants: it passes on the reducer, fails with
10 unexpected ticks when stop doesn't cancel the timer, and fails at the first `receive` when the
timer never starts or runs at the wrong interval.

`good/ConditionedYields.swift` is hand-written: one variant per shape the rule must let pass (a
single yield, a counted loop that checks a condition and leaves, a `while` poll with a deadline, a
loop whose variable hands over items between yields, yields inside child-task closures, and a
counted loop of `store.receive` calls).
