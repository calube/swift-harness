---
name: architecture
description: This skill should be used to design a new Swift module for a swift-harness app — pick its kind (feature, engine, render, library, client) from fit signals, then scaffold the Core/UI package pair or the Client/Live pair, declare it in .swiftgate.toml, and prove the layout with swiftgate arch. Use when the user wants to add a feature, screen, module, package, service, SDK wrapper, IO client, game loop or engine; asks "where should this code live", "should this be TCA", "which module kind"; or when `swiftgate arch` reports arch.undeclared-kind, arch.ui-framework-in-core, arch.live-dependency, arch.live-depends-on-feature, arch.vendor-dependency, arch.core-main-actor-isolation, arch.config-module-mismatch or arch.dependency-client-test-value.
---

# Architecture

Judgment layer over `swiftgate arch`: the gate is dogmatic, this skill decides. Rules cited as
`A1`, `D2`, `G1` live in the plugin's `docs/standards.md`; `P9`, `P10` in `docs/testing-playbook.md`.

`SG="${CLAUDE_PLUGIN_ROOT}/bin/swiftgate"`. Run every command from the repository root.

## 1. Read the current shape

1. Read `.swiftgate.toml`: `packages`, `[[modules]]` overrides, `[clients] vendor_modules`.
2. Run `"$SG" arch --json` and read only `verdict` and `findings[]` (`rule`, `file`, `message`).
   Existing arch findings are context; say so if the new work would add to them.

## 2. Choose the kind

Invariants for every kind: logic in a host-testable Core, a thin UI module, every source of
nondeterminism behind a dependency (`D1`), Core tests under `swift test` in seconds.

| Kind | Core shape | Pick it when |
|---|---|---|
| `feature` (default) | TCA `@Reducer` + exhaustive `TestStore` tests (`A3`, `A4`) | Event-driven screens and flows |
| `engine` | Pure `step(state, input, rng:) -> State`, fixed timestep, seeded RNG (`G1`) | Per-frame or >~30 Hz updates, render loops, high-rate sensor/audio/camera streams, hot pipelines |
| `render` | SpriteKit / `Canvas` / Metal reading engine state; no rules | Drawing an engine's state |
| `library` | Plain Swift | Shared utilities with no events or IO |
| `client` | `FooClient` interface + `FooClientLive` (`D2`–`D4`) | Anything doing IO: networking, images, analytics, logging, persistence, keychain, auth, flags, push, location |

Fit signals that argue against the `feature` default (spec §6.1, `A1`): per-frame state changes, a reducer that
would only forward calls to an SDK (ceremony), store overhead visible in a profile. Any IO at all
makes it a `client`, never a feature doing IO directly.

State the recommendation and the one-line reason. If two kinds genuinely fit, or the user's intent
is unclear (for example "a game board" could be `feature` or `engine` + `render`), ask with
`AskUserQuestion`: recommended option first, each option's consequence in its description. Don't
ask when the signals are unambiguous.

## 3. Scaffold

Mirror the harness's sample app, which the gate verifies (`examples/SampleApp/Packages/` in the
swift-harness repository; the installed plugin doesn't ship it): one
package per feature or client, two products each, `swiftLanguageModes: [.v6]`, `.macOS(.v15)` next
to `.iOS(.v18)` so Core tests run on the host, and the library pins from `docs/standards.md`
§ Library pins (features: TCA `exact: "1.26.2"` with the `ComposableArchitecture2Deprecations`
trait and swift-snapshot-testing `exact: "1.19.6"`; clients: swift-dependencies `exact: "1.17.1"`).

- **feature** — package `<Name>Feature`: products `<Name>Core` (reducer; no SwiftUI/UIKit import,
  `A2`; no MainActor default isolation, `C5`) and `<Name>UI` (views reading state and sending actions only, `A5`); test targets
  `<Name>CoreTests` (T1) and `<Name>UISnapshotTests` (T2). Name actions for what happened
  (`saveButtonTapped`), group `view` / `delegate` / internal (`A3`). No banned APIs (`A6`).
- **client** — package `<Name>Client`: products `<Name>Client` (`@DependencyClient struct`, models,
  `TestDependencyKey` with `static let testValue = Self()`, `D4`) and `<Name>ClientLive`
  (`extension <Name>Client: DependencyKey { static let liveValue }`, real IO, vendor SDKs, `D3`);
  test target `<Name>ClientLiveTests`, plus `<Name>ClientTests` once the interface has logic.
  Only the app target imports the Live product; features import the interface. List any vendor SDK in `[clients] vendor_modules`.
- **engine** — package `<Name>` with the pure step, a seeded RNG type and a replay test in
  `<Name>Tests` from the start (`P10`, `G1`). Rendering goes in a separate `render` module.
- **library** — one target and `<Name>Tests`.

Test targets are named `<Module>Tests` (or `<Module>…Tests` for T2): `impact` and T1 presence find
tests by that name (`P9`).

For `engine`, `render` and `library` modules, add the entry `arch.undeclared-kind` requires (`A1`).
Clients need none: the kind comes from the `*Client` / `*Live` names (an entry for a `*Live`
module must say `client`, or `arch.config-module-mismatch` fires):

```toml
[[modules]]
name = "<Module>"
kind = "engine"
reason = "<the fit signal, in one line>"
```

Add the package directory to `packages` if no glob covers it. Wire Live values only at the app's
composition root.

## 4. Prove the layout

1. `"$SG" arch --json` — must be GREEN; fix the layout, never waive a graph finding.
2. `"$SG" lint <new-dirs> --json` — determinism and client rules.
3. `"$SG" check --tier fast --json` — the new packages build and their (empty or first) tests run.

Report the kind, the one-line reason, the files created, and the three verdicts. Then hand the
behavior to `/swift-harness:tdd`: the scaffold carries no logic until a failing test asks for it.
