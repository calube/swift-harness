# Simulator QA accessibility audit

This page covers which controls `swiftgate sim verify` holds to standards §7 on each step's tree,
in an owned repository and in a brownfield clone. Read it when `sim verify` reports
`sim.a11y-identifier`, `sim.a11y-label`, `sim.a11y-untargeted` or `sim.tap-target`.

The rest of `sim verify` is in [`simulator-qa-sim.md`](simulator-qa-sim.md#sim-verify), and flow
rows in [`simulator-qa-flows.md`](simulator-qa-flows.md). Rule ids are in
[`standards.md` § Rule id index](standards.md#rule-id-index).

## The 2 rules

Each step's tree must show every button, switch, text field and cell with an accessibility
identifier (`sim.a11y-identifier`) and a readable label (`sim.a11y-label`).

- A label is readable when it holds more than whitespace and differs from the identifier.
- Static text, images and containers need neither.
- These 2 rules check standards §7 on the screen the app drew. An icon-only button with no
  `.accessibilityLabel` fails here even when review missed it.
- A text field shows its title only as its placeholder, so a field needs `.accessibilityLabel`
  too. `lint` and each slice gate check that in the changed Swift sources as `a11y.input-label`.

## Scope

An owned repository, one with a committed `.swiftgate.toml`, judges every control on every step,
with a flow or without one.

A brownfield clone inherits controls the change never touched, so a whole-screen audit would make
every flow RED. There, `qa run` judges only the controls its flow file names by `id=`: the
identifiers the change's contract gives its new controls.

- Selectors come from a step's input, outside what a step types or compares.
- Matching follows the pinned `agent-device`: trimmed, case-folded, with `||` between
  alternatives.
- The audit judges a control when an alternative holding an `id=` term matches it, even if a
  `label=` selector reaches it too.
- A control the flow reaches only by `role=`, `label=`, `value=` or `text=` is existing UI the
  flow navigates through, such as a tab it taps by its title. Its findings don't gate.
- A standalone `sim verify` in a brownfield clone has no flow, so it judges no control, and its
  nit says why.

## The 2 nits

`sim.a11y-untargeted` gathers every control the audit left out that has a finding into 1 nit. The
nit gives the count, with the navigated controls counted apart. For example: "9 controls no flow
step selects by id (1 the flow only navigates through) lack an accessibility identifier or a
readable label". A control counts once however many steps show it. The audit matches controls by
role, identifier and label, or by frame when a control has neither.

`sim.tap-target` measures each control a `press` step selects. Each one drawn under 44×44 pt on a
side goes into 1 nit that names it with its size, such as "Button cart.line.muffin.increment 20×19
pt".

Neither nit changes the verdict. `sim/report.json` lists each under `notes` as `{rule, message}`.
The text output prints it as a `nit` line, the history line carries it as a nit-severity finding,
and a flow row's message ends with it.
