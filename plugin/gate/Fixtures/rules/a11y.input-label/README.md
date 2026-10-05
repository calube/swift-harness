# `a11y.input-label` fixtures

`bad/DetailView.swift` and `good/DetailView.swift` are a real view, captured from a practice
trial's contract commit and from the fixer's commit that labeled its field, with the app's domain
words renamed. The bad one's draft field, `TextField("Note", text:)` with only an
`.accessibilityIdentifier`, exposed its title as a placeholder and no label, so `sim.a11y-label`
failed every flow row that reached the screen, at the last task's before-merge qa. The fix was
the 1 line `.accessibilityLabel("Note")`. From the trial clone, with `<view>` the view's
repository-relative path and `<rename>` a `sed` script that renames the app's 7 domain words (its
screen, record and field names) to `Detail`, `Note`, `item`, `title` and `isMine`, kept out of this
repository so the fixture names no app:

```sh
git show 7aa60b1^:<view> | sed -e "<rename>" > bad/DetailView.swift
git show 7aa60b1:<view> | sed -e "<rename>" > good/DetailView.swift
```

`good/LabeledFields.swift` is hand-written: one variant per shape the rule must let pass (a label
anywhere in the field's modifier chain, a `Text` label, a field inside `LabeledContent`, a field
with a `prompt:` whose title then names it, a container carrying the label, and a field with no
identifier, which no flow selects).
