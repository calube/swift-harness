import Foundation

/// Where a sprint stands. Closed: `sprint.json` naming any other step fails decoding.
public enum SprintStep: Sendable, Equatable {
  case started
  case surfaced
  /// Slices `1...n` have passed.
  case slicing(Int)
  case finished
}

public enum SprintSliceStatus: String, Sendable, Equatable, CaseIterable {
  case pending
  case passed
}

/// One slice of the spec page, numbered from 1 in the page's order.
public struct SprintSlice: Sendable, Equatable {
  public let number: Int
  public let status: SprintSliceStatus
  /// The `push` gate run the slice passed with; `nil` until it passes.
  public let gateRun: String?
}

/// One sprint's recorded state, as `sprint.json` holds it. Only ``SprintTransition`` and
/// ``SprintRunJSON/decode(_:)`` make one, so every run a caller holds went through the state
/// machine or its validation.
public struct SprintRun: Sendable, Equatable {
  public let slug: String
  /// The spec page the slices come from, as the caller named it.
  public let specPage: String
  /// `sprint/<slug>`.
  public let branch: String
  /// `main`'s full sha when the sprint started; `finish` fast-forwards only from it.
  public let baseCommit: String
  /// The surface commit's full sha; `nil` until `surface`.
  public let surfaceCommit: String?
  public let slices: [SprintSlice]
  /// The final `ready` gate run; `nil` until `finish`.
  public let finalGateRun: String?
  public let step: SprintStep

  init(
    slug: String, specPage: String, branch: String, baseCommit: String, surfaceCommit: String?,
    slices: [SprintSlice], finalGateRun: String?, step: SprintStep
  ) {
    self.slug = slug
    self.specPage = specPage
    self.branch = branch
    self.baseCommit = baseCommit
    self.surfaceCommit = surfaceCommit
    self.slices = slices
    self.finalGateRun = finalGateRun
    self.step = step
  }

  /// The only step the state machine accepts next.
  public var next: SprintNextStep { .start }
}

/// Why `sprint.json` didn't decode, naming the field at fault.
public enum SprintRunJSONError: Error, Sendable, Equatable {
  case notJSON(String)
  case invalid(field: String, reason: String)

  public var message: String { "" }
}

/// `sprint.json`: one pretty-printed, key-sorted object with a trailing newline, so encoding a
/// decoded file gives back the same bytes.
public enum SprintRunJSON {
  public static let schemaVersion = 1

  public static func encode(_ run: SprintRun) throws -> Data { .init() }

  public static func decode(_ data: Data) throws(SprintRunJSONError) -> SprintRun {
    throw .notJSON("")
  }
}
