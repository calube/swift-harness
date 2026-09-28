/// The step a sprint must take next.
public enum SprintNextStep: Sendable, Equatable {
  case start
  case surface
  case slice(Int)
  case finish

  /// How the step reads in a refusal: `start`, `surface`, `slice 2`, `finish`.
  public var description: String {
    switch self {
    case .start: "start"
    case .surface: "surface"
    case .slice(let n): "slice \(n)"
    case .finish: "finish"
    }
  }
}

/// One `swiftgate sprint` command's request.
public enum SprintEvent: Sendable, Equatable {
  case start(slug: String, specPage: String, baseCommit: String, sliceCount: Int)
  case surface(commit: String)
  case slice(Int, gateRun: String)
  case finish(gateRun: String)

  var step: SprintNextStep {
    switch self {
    case .start: .start
    case .surface: .surface
    case .slice(let n, _): .slice(n)
    case .finish: .finish
    }
  }
}

/// Every case leaves the run as it was.
public enum SprintTransitionError: Error, Sendable, Equatable {
  /// The event isn't the step the state machine expected.
  case outOfOrder(attempted: SprintNextStep, expected: SprintNextStep)
  case invalidSlug(String)
  case invalidSpecPage(String)
  case invalidCommit(String)
  case invalidGateRun(String)
  case invalidSliceCount(Int)

  public var message: String {
    switch self {
    case .outOfOrder(let attempted, let expected):
      "sprint expected \(expected.description), got \(attempted.description)"
    case .invalidSlug(let slug):
      "sprint slug \(slug) is not lowercase letters and digits joined by single hyphens"
    case .invalidSpecPage(let path): "sprint spec page \"\(path)\" is not a path"
    case .invalidCommit(let sha): "\(sha) is not a full commit sha"
    case .invalidGateRun(let id): "\"\(id)\" is not a gate run id"
    case .invalidSliceCount(let count): "a sprint needs at least 1 slice, not \(count)"
    }
  }
}

/// The sprint state machine (fast-modes spec §4.2): start, surface, slices 1 to n in the page's
/// order, finish. A finished sprint accepts only a new start.
public enum SprintTransition {
  /// The run after `event`, or why the event is refused. Order is checked before the event's
  /// values, so a refusal for the wrong step always names the step that was expected.
  public static func apply(_ event: SprintEvent, to run: SprintRun?)
    throws(SprintTransitionError) -> SprintRun
  {
    let expected = run?.next ?? .start
    guard event.step == expected else {
      throw .outOfOrder(attempted: event.step, expected: expected)
    }
    if case .start(let slug, let specPage, let baseCommit, let sliceCount) = event {
      guard SprintRun.isValidSlug(slug) else { throw .invalidSlug(slug) }
      guard SprintRun.isValidSpecPage(specPage) else { throw .invalidSpecPage(specPage) }
      guard SprintRun.isValidCommit(baseCommit) else { throw .invalidCommit(baseCommit) }
      guard sliceCount >= 1 else { throw .invalidSliceCount(sliceCount) }
      return SprintRun(
        slug: slug, specPage: specPage, branch: SprintRun.branch(for: slug),
        baseCommit: baseCommit, surfaceCommit: nil,
        slices: (1...sliceCount).map { SprintSlice(number: $0, status: .pending, gateRun: nil) },
        finalGateRun: nil, step: .started)
    }
    // Without a run the only expected step is `start`, which the order check already required.
    guard let run else { throw .outOfOrder(attempted: event.step, expected: .start) }
    switch event {
    case .start:
      return run
    case .surface(let commit):
      guard SprintRun.isValidCommit(commit) else { throw .invalidCommit(commit) }
      return run.replacing(surfaceCommit: commit, step: .surfaced)
    case .slice(let n, let gateRun):
      guard SprintRun.isValidGateRun(gateRun) else { throw .invalidGateRun(gateRun) }
      var slices = run.slices
      slices[n - 1] = SprintSlice(number: n, status: .passed, gateRun: gateRun)
      return run.replacing(slices: slices, step: .slicing(n))
    case .finish(let gateRun):
      guard SprintRun.isValidGateRun(gateRun) else { throw .invalidGateRun(gateRun) }
      return run.replacing(finalGateRun: gateRun, step: .finished)
    }
  }
}

extension SprintRun {
  fileprivate func replacing(
    surfaceCommit: String? = nil, slices: [SprintSlice]? = nil, finalGateRun: String? = nil,
    step: SprintStep
  ) -> SprintRun {
    SprintRun(
      slug: slug, specPage: specPage, branch: branch, baseCommit: baseCommit,
      surfaceCommit: surfaceCommit ?? self.surfaceCommit, slices: slices ?? self.slices,
      finalGateRun: finalGateRun ?? self.finalGateRun, step: step)
  }
}
