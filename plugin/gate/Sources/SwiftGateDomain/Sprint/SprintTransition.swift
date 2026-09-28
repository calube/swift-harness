/// The step a sprint must take next.
public enum SprintNextStep: Sendable, Equatable {
  case start
  case surface
  case slice(Int)
  case finish

  /// How the step reads in a refusal: `start`, `surface`, `slice 2`, `finish`.
  public var description: String { "" }
}

/// One `swiftgate sprint` command's request.
public enum SprintEvent: Sendable, Equatable {
  case start(slug: String, specPage: String, baseCommit: String, sliceCount: Int)
  case surface(commit: String)
  case slice(Int, gateRun: String)
  case finish(gateRun: String)
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

  public var message: String { "" }
}

/// The sprint state machine (fast-modes spec §4.2): start, surface, slices 1 to n in the page's
/// order, finish. A finished sprint accepts only a new start.
public enum SprintTransition {
  public static func apply(_ event: SprintEvent, to run: SprintRun?)
    throws(SprintTransitionError) -> SprintRun
  {
    throw .outOfOrder(attempted: .start, expected: .start)
  }
}
