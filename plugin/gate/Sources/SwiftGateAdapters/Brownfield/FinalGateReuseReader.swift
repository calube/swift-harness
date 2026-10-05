import Foundation
import SwiftGateDomain

/// What a `final` gate not yet run in a checkout would still run: its config's areas, each step
/// looked up in the clone's area-step passes under the inputs `final` would run on now.
public enum FinalGateReuseReader {
  /// `nil` when any input `final` keys its reuse on can't be read, so nothing is known reused: a
  /// dirty tree, no merge base with `base`, no binary hash, or no brownfield config.
  /// - Parameter root: the checkout's toplevel, as `check --tier final` gates from it.
  public static func read(root: URL, base: String, sourceHash: String?) async -> FinalGateReuse? {
    guard
      let reader = await BrownfieldGateReuseReader.live(
        root: root, runner: LiveProcessRunner(), sourceHash: sourceHash),
      let inputs = await reader.inputs(tier: .final, base: base),
      let baseTree = try? await reader.tree(inputs.mergeBase),
      case .brownfield(let config)? = try? ConfigLoader().loadProfile(
        repositoryRoot: root, commonDir: reader.layout.commonDir)
    else { return nil }
    let store = AreaStepResults(layout: reader.layout)
    return FinalGateReuse(
      areas: FinalGateReuse.areas(
        config.areas, inputs: inputs, repositoryRoot: root.path(percentEncoded: false),
        layout: reader.layout, passed: { store.pass($0) != nil }),
      times: WarmupTimesStore(layout: reader.layout).load(tree: baseTree).file)
  }
}
