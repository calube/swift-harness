# Context pack: `formal-greeting` (plan `calibrate`)

## Task

- Id: `formal-greeting` · Gate: `fast` · Model: sonnet
- Writes: `Sources/Greeter/Greeter.swift`, `Tests/GreeterTests/GreeterTests.swift`
- Does: add a formal greeting beside the plain one.
- Tests: `test-formal-greeting`, `test-informal-greeting`

## Design: Decision

`Greeter` gains `public static func greet(_ name: String, formal: Bool) -> String`.

- `formal: true` returns `Good day, <name>.` (with the full stop).
- `formal: false` returns exactly what `greet(_:)` returns, `Hello, <name>`.
- `greet(_:)` keeps its signature and behaviour.

## Tests

- `test-formal-greeting`: `greet("Ada", formal: true)` is `Good day, Ada.`
- `test-informal-greeting`: `greet("Ada", formal: false)` is `Hello, Ada`

## Standards

`Greeter` is a `library` module: plain Swift, no reducers, no dependencies. Tests use Swift Testing
and are named `"<behaviour> — catches <regression>"`.

## Dependencies

None.
