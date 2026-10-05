import Foundation

/// Where an area's commands build in a checkout: the user's, the plan branch's or a task slot.
///
/// An `xcodebuild` builds in the checkout's own DerivedData (``XcodeDerivedData``): Xcode keys a
/// build by the project's absolute path, so a DerivedData shared between checkouts recompiles
/// every target each time the checkout changes. A `swift build` or `swift test` builds in the
/// area's 1 scratch path every tree of the clone shares (``ScratchTreeBuild``): SwiftPM keeps the
/// fetched and built dependencies under the scratch path, so a checkout's first build compiles only
/// the area's own modules again, where a `.build` of its own would compile every dependency cold.
public enum AreaBuildPlacement {
  /// `request` as a checkout runs it for an area of `kind`.
  public static func checkout(
    _ request: AreaCommandRequest, kind: AreaKind, layout: BrownfieldStateLayout
  ) -> AreaCommandRequest {
    switch kind {
    case .swiftpm: ScratchTreeBuild.swiftPMRequest(request, layout: layout)
    default: XcodeDerivedData.request(request, layout: layout)
    }
  }
}
