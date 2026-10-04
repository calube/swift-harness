# Counter reset and floor

The counter screen gains a way to start over, and its count never drops below zero.

## Requirements

1. Reset. A reset button on the counter screen sets the count back to zero.
2. Floor. Decrementing at zero leaves the count at zero.

## Acceptance

- Tapping reset after incrementing twice shows a count of 0.
- Tapping decrement when the count is 0 keeps the count at 0.

## Out of scope

- Persisting the count across launches.
- Any change to the cat fact or the game engine.
