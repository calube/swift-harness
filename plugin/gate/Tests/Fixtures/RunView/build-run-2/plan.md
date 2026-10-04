# Counter reset and floor

Spec: docs/specs/counter-reset-and-floor.md

## Goal
A user can tap a reset button on the counter screen to set the count back to zero, and the count never drops below zero when they tap decrement.

## Modules
| Module | Kind | Owns | Depends on |
|---|---|---|---|
| CounterCore | feature | the counter reducer: count, reset and floor rules | APIClient, LogClient |
| CounterUI | feature | the counter screen and its reset button | CounterCore |

## Surface
- `CounterFeature.Action`: new case `resetButtonTapped`
- `CounterView`: a Reset button, accessibility identifier `counter.reset`, that sends `.resetButtonTapped`

## Slices
1. Reset sets the count back to zero and clears a shown fact. Test: `resetAfterIncrementsShowsZero`: after 2 increments, sending `resetButtonTapped` leaves the count at 0. Spec: "Tapping reset after incrementing twice shows a count of 0."
2. Decrement stops at zero. Test: `decrementAtZeroStaysZero`: sending `decrementButtonTapped` at a count of 0 leaves the count at 0. Spec: "Tapping decrement when the count is 0 keeps the count at 0."

## Out of scope
- Persisting the count across launches.
- Any change to the cat fact or the game engine.
