This run gives you no tools. Your context pack is inline below, and it holds everything you
would otherwise read from disk.

# Standards conformance pack

## Module kinds

| Module | Kind | Reason |
|---|---|---|
| PhotoEditorCore | feature | reducer for crop, rotate and undo |
| ImageRendererClient | client | interface: `crop(ImageData, CropRect) async throws -> ImageData` |
| ImageRendererClientLive | client | UIKit renderer behind the interface; `host_testable = false` |
| PhotoEditorUI | library | SwiftUI views for the editor |

## Decision

- Choose Option 2: PhotoEditorCore imports only Foundation, ComposableArchitecture and ImageRendererClient, and crops through `@Dependency(ImageRendererClient.self)`.
- ImageRendererClientLive imports UIKit and is imported by the app target only.
- PhotoEditorUI renders the state and sends actions.

## Test plan by tier

- test-crop-updates-the-edited-image: the reducer crops through a stubbed ImageRendererClient — tier T1
- test-renderer-client-crops-to-rect: ImageRendererClientLive crops a fixture image to the rect — tier T2
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
