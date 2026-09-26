This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Standards conformance pack

## Module kinds

| Module | Kind | Reason |
|---|---|---|
| PhotoEditorCore | feature | reducer for crop, rotate and undo |
| PhotoEditorUI | library | SwiftUI views for the editor |

## Decision

- Choose Option 1: PhotoEditorCore crops and rotates with `UIImage` and `UIGraphicsImageRenderer`, so PhotoEditorCore imports UIKit next to ComposableArchitecture.
- PhotoEditorUI renders the state and sends actions.

## Test plan by tier

- test-crop-updates-the-edited-image: the reducer crops the image to the chosen rect — tier T1
- test-editor-matches-snapshot: the editor view snapshot — tier T2

## Standards for the module kinds in scope

**A2. Core imports no UI framework.**
- **Do:** Core modules import Foundation, TCA, Dependencies and other Cores/interfaces only.
- **Tell:** `import SwiftUI` or `import UIKit` in a Core module; a Core test that needs a simulator.

**A5. No logic in views.**
- **Do:** views read state and send actions. Formatting that needs a test goes in State or Core.

**D2. Every service is a `FooClient` / `FooClientLive` pair.**
- **Do:** two modules. `FooClient` holds the `@DependencyClient struct` and may import Foundation, Dependencies and other interfaces. `FooClientLive` holds `liveValue`, real IO and vendor SDKs, and is imported by the app target only. A Live module that needs UIKit declares `host_testable = false` in `.swiftgate.toml`.

**D3. IO and vendor SDKs live only in `*Live` modules.**

**P9.** Every changed Core, client or live module has a test in the plan.
