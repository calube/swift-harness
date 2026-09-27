# 0003. Ship may skip the design step

Status: proposed, 2026-09-27. Awaits the user's approval with the fast modes design
(`docs/designs/2026-09-27-fast-modes-design.md`). Changes the build executor spec §3.1 and §5.1.

## Context

`/swift-harness:ship` runs design, plan and build, and its skill says never to skip a step. Two timed trial runs
spent 13–14 minutes on design and plan before any code, most of it in frame prompts and drafter rounds. The spec in
both runs already said what to build. The design step's research lane, probes and evidence check answer "what should
we build and is it feasible"; for a spec that already answers that, they add time and no new facts.

## Decision

A preset may set `design_tier = "none"`. Ship then replaces design and plan's design doc with a 1-page spec the
user confirms once, and builds from a surface commit that `swiftgate surface-check` proves has no behaviour.

Only a preset or an explicit flag selects it; `design-scope` never recommends it. The quality floor in the fast
modes design §6 still holds: test-first, same-line reasons on escape hatches, GREEN merge gates, and 1 final
`ready` gate over everything the build added.

## Consequences

- Code starts at about minute 7 instead of 13–14 in a timed run (estimated from trial run 2's phase times).
- No research lane or evidence check: a wrong assumption in the spec surfaces as a failing test or a RED gate, not as
  a design finding. That's acceptable only when the spec states what to build.
- `plan-lint` needs a second coverage source, the spec page's acceptance tests.
- The design skill and its gates are unchanged; every other preset still runs them.
