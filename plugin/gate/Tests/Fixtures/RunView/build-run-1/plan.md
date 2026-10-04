# Counter reset and floor

Spec: docs/specs/counter-reset-and-floor.md

## Goal
A user can tap reset on the counter screen to set the count back to zero. Decrementing at zero leaves the count at zero.

## Modules
| Module | Kind | Owns | Depends on |
|---|---|---|---|
| CounterCore | feature | the counter reducer, its state and actions | APIClient, LogClient |
| CounterUI | feature | the counter screen and its reset button | CounterCore |

## Surface
- `CounterFeature.Action`: a new `resetButtonTapped` case, which the reducer handles with `.none`.

## Slices
1. Reset sets the count to zero, and the counter screen shows a reset button that sends `resetButtonTapped`. Test: `resetAfterIncrementsShowsZero`: after 2 increments, reset sets the count to 0. Spec: "Tapping reset after incrementing twice shows a count of 0."
2. Decrement stops at zero. Test: `decrementAtZeroStaysZero`: decrement at a count of 0 leaves the count at 0. Spec: "Tapping decrement when the count is 0 keeps the count at 0."

## Out of scope
- Persisting the count across launches.
- Any change to the cat fact or the game engine.
