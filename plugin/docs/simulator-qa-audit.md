# Simulator QA accessibility audit

Which controls `swiftgate sim verify` holds to standards §7 on each step's tree. The rest of
`sim verify` is in [`simulator-qa-sim.md`](simulator-qa-sim.md#sim-verify), and flow rows in
[`simulator-qa-flows.md`](simulator-qa-flows.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## The 2 rules

Each step's tree must show every button, switch, text field and cell with an accessibility
identifier (`sim.a11y-identifier`) and a readable label (`sim.a11y-label`). A label is readable when
it holds more than whitespace and differs from the identifier. Static text, images and containers
need neither. These 2 rules check standards §7 on the screen the app drew, so an icon-only
button with no `.accessibilityLabel` fails here even when review missed it.

## Scope

An owned repository (a committed `.swiftgate.toml`) judges every control on every step, with a flow
or without one.

A brownfield clone inherits controls the change never touched, so a whole-screen audit would make
every flow RED. There, `qa run` judges only the controls its flow file names by `id=`: the
identifiers the change's contract gives its new controls. Selectors come from a step's input,
outside what a step types or compares. Matching follows the pinned `agent-device`: trimmed,
case-folded, `||` between alternatives. The audit judges a control when an alternative holding an `id=`
term matches it, even if a `label=` selector reaches it too.

A control the flow reaches only by `role=`, `label=`, `value=` or `text=` is existing UI it
navigates through, such as a tab it taps by its title. Its findings don't gate.

Every control left out with a finding becomes part of 1 `sim.a11y-untargeted` nit that gives the
count, with the navigated ones counted apart, such as "9 controls no flow step selects by id (1 the
flow only navigates through) lack an accessibility identifier or a readable label". A control
counts once however many steps show it: the same role, identifier and label, or, with neither, the
same frame. A standalone `sim verify` in a brownfield clone has no flow, so it judges no control,
and its nit says why.

A control a `press` step selects is measured too. Any drawn under 44×44 pt on a side earns 1
`sim.tap-target` nit naming each with its size, such as "Button cart.line.muffin.increment 20×19
pt".

Neither nit changes the verdict. `sim/report.json` lists it under `notes` as `{rule, message}`,
the text prints it as a `nit` line, the history line carries it as a nit-severity finding, and a
flow row's message ends with it.
