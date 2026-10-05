import Foundation

/// 1 area as a `final` gate not yet run would run it: the steps no recorded pass on the plan
/// tip's tree covers.
public struct FinalGateArea: Sendable, Equatable {
  public let name: String
  /// Empty when `final` takes every step of the area from an earlier pass.
  public let unreused: [AreaStep]

  public init(name: String, unreused: [AreaStep]) {
    self.name = name
    self.unreused = unreused
  }
}

/// What a `final` gate not yet run would still have to run, and the warm-up times that price it.
/// `final` takes an area command's pass from any tier on the same tree, so after a merge gate
/// only the areas that merge didn't touch, and each area's `e2e`, are left to run.
public struct FinalGateReuse: Sendable, Equatable {
  /// The steps `final` runs for each area, in order.
  public static let steps: [AreaStep] = [.build, .test, .lint, .e2e]

  public let areas: [FinalGateArea]
  /// The warm-up times at the merge base `final` measures from.
  public let times: WarmupTimesFile

  public init(areas: [FinalGateArea], times: WarmupTimesFile) {
    self.areas = areas
    self.times = times
  }

  /// Each of `areas`' ``steps`` that has a command, with the steps whose
  /// ``GateReuse/areaStepKey(_:area:step:command:)`` under `inputs` `passed` doesn't hold. A lint
  /// command that takes `{files}` is left out: `final` runs it only on the files changed since
  /// the merge base, which a price needn't read.
  /// - Parameters:
  ///   - repositoryRoot: the checkout `final` runs in, absolute.
  ///   - layout: that checkout's state, for each test step's `{junit}` path.
  public static func areas(
    _ areas: [BrownfieldArea], inputs: GateReuse.Inputs, repositoryRoot: String,
    layout: BrownfieldStateLayout, passed: (_ key: String) -> Bool
  ) -> [FinalGateArea] {
    areas.map { area in
      let unreused = steps.filter { step in
        guard let template = AreaCommandExpansion.template(for: step, in: area),
          !(step == .lint && template.contains(AreaCommandExpansion.filesPlaceholder)),
          let prepared = AreaCommandExpansion.prepare(
            area: area, step: step, repositoryRoot: repositoryRoot, files: [], tests: [],
            junitPath: AreaCommandExpansion.junitPath(layout: layout, area: area.name, step: step),
            deadline: .zero, environment: [:])
        else { return false }
        return !passed(
          GateReuse.areaStepKey(
            inputs, area: area.name, step: step, command: prepared.request.command))
      }
      return FinalGateArea(name: area.name, unreused: unreused)
    }
  }

  /// How long the steps left take, in whole seconds: areas run side by side, so the slowest
  /// area's. An area with steps left costs its warm test when the warm-up measured one, else its
  /// cold cost; `unmeasured` when neither, or when an `e2e` step, which no warm-up times, is
  /// left. 0 when every step is reused.
  public func seconds(unmeasured: Int) -> Int {
    areas.filter { !$0.unreused.isEmpty }.map { area in
      guard !area.unreused.contains(.e2e), let record = times.areas[area.name] else {
        return unmeasured
      }
      return ((record.warmTestMilliseconds ?? record.coldMilliseconds) + 999) / 1000
    }.max() ?? 0
  }
}
