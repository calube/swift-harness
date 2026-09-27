# Routing re-check after the `design` description change and the new `ship` and `build` skills, 2026-09-27

Merge `ship-skill-and-sketch-design-flow` changed the end of the `design` description to add
`--tier sketch`, and added 2 skills, `ship` and `build`, whose descriptions claim "build this README
end to end" and building a planned ledger. `main` `fde163e`, staged with
`evals/runner/stage_plugin.sh`, `claude-opus-5-5`, `max_turns: 1`.

**Result: no regression and no wrong load into `ship` or `build`.**

| Set | Runs | Result | pass^k | USD |
|---|---|---|---|---|
| `design` and `plan` held-out, rounds 4 (16 cases × 3) | 48 | `design` 1.00/1.00, `plan` 1.00/1.00; near-miss owners `review`, `status`, `tdd` and `none` all right | 16 of 16 | 2.91 |
| `tdd` held-out, rounds 1 to 3 (24 cases × 1) | 24 | `tdd` 1.00/1.00; `architecture`, `validate` and `none` near-misses right | 24 of 24 | 1.70 |

The `tdd` set ran 1 trial as a screen for wrong loads: `ship` claims "a spec that already states what
to build", which sits next to `tdd`'s "implement a feature". No trial loaded `ship` or `build`.

**Not covered:** `ship` and `build` have no routing cases of their own yet, so their recall and the
requests that should route to them are unmeasured.
