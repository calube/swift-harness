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
  public var next: SprintNextStep {
    switch step {
    case .started: .surface
    case .surfaced: .slice(1)
    case .slicing(let n): n < slices.count ? .slice(n + 1) : .finish
    case .finished: .start
    }
  }

  static func branch(for slug: String) -> String { "sprint/" + slug }

  /// Lowercase ASCII words joined by single hyphens, so `sprint/<slug>` is a valid branch and the
  /// slug a single path component.
  static func isValidSlug(_ slug: String) -> Bool {
    let words = slug.split(separator: "-", omittingEmptySubsequences: false)
    return words.allSatisfy { word in
      !word.isEmpty
        && word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
  }

  static func isValidSpecPage(_ path: String) -> Bool {
    !path.isEmpty && !path.contains { $0.isNewline || $0 == "\0" }
  }

  /// A full sha: 40 lowercase hex digits, or 64 in a SHA-256 repository. An abbreviated sha can
  /// stop naming one commit as the repository grows.
  static func isValidCommit(_ sha: String) -> Bool {
    (sha.utf8.count == 40 || sha.utf8.count == 64)
      && sha.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }

  static func isValidGateRun(_ id: String) -> Bool { !id.isEmpty && RunID.isValid(id) }

  /// Whether the step agrees with the rest of the run: the surface is recorded from `surfaced`
  /// on, exactly the first `n` slices have passed at `slicing(n)`, and only `finished` has a
  /// final gate run.
  var stepMatchesFields: Bool {
    let passed = slices.prefix { $0.status == .passed }.count
    let passedAreAPrefix = slices.dropFirst(passed).allSatisfy { $0.status == .pending }
    guard passedAreAPrefix else { return false }
    switch step {
    case .started:
      return surfaceCommit == nil && passed == 0 && finalGateRun == nil
    case .surfaced:
      return surfaceCommit != nil && passed == 0 && finalGateRun == nil
    case .slicing(let n):
      return surfaceCommit != nil && passed == n && finalGateRun == nil
    case .finished:
      return surfaceCommit != nil && passed == slices.count && finalGateRun != nil
    }
  }
}

/// Why `sprint.json` didn't decode, naming the field at fault.
public enum SprintRunJSONError: Error, Sendable, Equatable {
  case notJSON(String)
  /// `field` is a path into the file, such as `step.name` or `slices[2].status`.
  case invalid(field: String, reason: String)

  public var message: String {
    switch self {
    case .notJSON(let detail): "sprint.json is not JSON: \(detail)"
    case .invalid(let field, let reason): "sprint.json field \(field): \(reason)"
    }
  }
}

/// `sprint.json`: one pretty-printed, key-sorted object with a trailing newline, so encoding a
/// decoded file gives back the same bytes. Optional fields are absent, never `null`, until known.
public enum SprintRunJSON {
  public static let schemaVersion = 1

  public static func encode(_ run: SprintRun) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(FileShape(run))
    data.append(UInt8(ascii: "\n"))
    return data
  }

  public static func decode(_ data: Data) throws(SprintRunJSONError) -> SprintRun {
    let shape: FileShape
    do {
      shape = try JSONDecoder().decode(FileShape.self, from: data)
    } catch let error as DecodingError {
      throw Self.error(from: error)
    } catch {
      throw .notJSON(String(describing: error))
    }
    return try shape.run()
  }

  private static func error(from error: DecodingError) -> SprintRunJSONError {
    switch error {
    case .keyNotFound(let key, let context):
      return .invalid(field: field(context.codingPath + [key]), reason: "missing")
    case .typeMismatch(_, let context), .valueNotFound(_, let context):
      return .invalid(field: field(context.codingPath), reason: context.debugDescription)
    case .dataCorrupted(let context):
      guard !context.codingPath.isEmpty else {
        return .notJSON(
          (context.underlyingError).map { String(describing: $0) } ?? context.debugDescription)
      }
      return .invalid(field: field(context.codingPath), reason: context.debugDescription)
    @unknown default:
      return .notJSON(String(describing: error))
    }
  }

  private static func field(_ path: [any CodingKey]) -> String {
    path.reduce(into: "") { text, key in
      if let index = key.intValue {
        text += "[\(index)]"
      } else {
        text += (text.isEmpty ? "" : ".") + key.stringValue
      }
    }
  }
}

/// The file as JSON types; ``run()`` turns it into a ``SprintRun`` or names the bad field.
private struct FileShape: Codable {
  let schemaVersion: Int
  let slug: String
  let specPage: String
  let branch: String
  let baseCommit: String
  let surfaceCommit: String?
  let slices: [SliceShape]
  let finalGateRun: String?
  let step: StepShape

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, slug, specPage, branch, baseCommit, surfaceCommit, slices, finalGateRun,
      step
  }

  init(_ run: SprintRun) {
    schemaVersion = SprintRunJSON.schemaVersion
    slug = run.slug
    specPage = run.specPage
    branch = run.branch
    baseCommit = run.baseCommit
    surfaceCommit = run.surfaceCommit
    slices = run.slices.map(SliceShape.init)
    finalGateRun = run.finalGateRun
    step = StepShape(run.step)
  }

  init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    slug = try c.decode(String.self, forKey: .slug)
    specPage = try c.decode(String.self, forKey: .specPage)
    branch = try c.decode(String.self, forKey: .branch)
    baseCommit = try c.decode(String.self, forKey: .baseCommit)
    surfaceCommit = try c.decodeIfPresent(String.self, forKey: .surfaceCommit)
    slices = try c.decode([SliceShape].self, forKey: .slices)
    finalGateRun = try c.decodeIfPresent(String.self, forKey: .finalGateRun)
    step = try c.decode(StepShape.self, forKey: .step)
  }

  func run() throws(SprintRunJSONError) -> SprintRun {
    func require(_ valid: Bool, _ field: String, _ reason: String) throws(SprintRunJSONError) {
      if !valid { throw .invalid(field: field, reason: reason) }
    }
    try require(
      schemaVersion == SprintRunJSON.schemaVersion, "schemaVersion",
      "\(schemaVersion) is not \(SprintRunJSON.schemaVersion)")
    try require(SprintRun.isValidSlug(slug), "slug", "\(slug) is not a lowercase hyphenated slug")
    try require(SprintRun.isValidSpecPage(specPage), "specPage", "\(specPage) is not a path")
    try require(
      branch == SprintRun.branch(for: slug), "branch",
      "\(branch) is not \(SprintRun.branch(for: slug))")
    try require(
      SprintRun.isValidCommit(baseCommit), "baseCommit", "\(baseCommit) is not a full sha")
    if let surfaceCommit {
      try require(
        SprintRun.isValidCommit(surfaceCommit), "surfaceCommit",
        "\(surfaceCommit) is not a full sha")
    }
    try require(!slices.isEmpty, "slices", "a sprint has at least 1 slice")
    var parsed: [SprintSlice] = []
    for (index, slice) in slices.enumerated() {
      parsed.append(try slice.slice(at: index))
    }
    if let finalGateRun {
      try require(
        SprintRun.isValidGateRun(finalGateRun), "finalGateRun", "\(finalGateRun) is not a run id")
    }
    let run = SprintRun(
      slug: slug, specPage: specPage, branch: branch, baseCommit: baseCommit,
      surfaceCommit: surfaceCommit, slices: parsed, finalGateRun: finalGateRun,
      step: try step.step())
    try require(
      run.stepMatchesFields, "step",
      "\(step.name) disagrees with the recorded surface, slices or final gate run")
    return run
  }
}

private struct SliceShape: Codable {
  let number: Int
  let status: String
  let gateRun: String?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case number, status, gateRun
  }

  init(_ slice: SprintSlice) {
    number = slice.number
    status = slice.status.rawValue
    gateRun = slice.gateRun
  }

  init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    number = try c.decode(Int.self, forKey: .number)
    status = try c.decode(String.self, forKey: .status)
    gateRun = try c.decodeIfPresent(String.self, forKey: .gateRun)
  }

  func slice(at index: Int) throws(SprintRunJSONError) -> SprintSlice {
    let field = "slices[\(index)]"
    guard number == index + 1 else {
      throw .invalid(field: field + ".number", reason: "\(number) is not \(index + 1)")
    }
    guard let parsed = SprintSliceStatus(rawValue: status) else {
      throw .invalid(
        field: field + ".status",
        reason: "\(status) is not one of "
          + SprintSliceStatus.allCases.map(\.rawValue).joined(separator: ", "))
    }
    switch (parsed, gateRun) {
    case (.pending, nil):
      break
    case (.pending, .some):
      throw .invalid(field: field + ".gateRun", reason: "a pending slice has no gate run")
    case (.passed, nil):
      throw .invalid(field: field + ".gateRun", reason: "a passed slice names its gate run")
    case (.passed, .some(let id)):
      guard SprintRun.isValidGateRun(id) else {
        throw .invalid(field: field + ".gateRun", reason: "\(id) is not a run id")
      }
    }
    return SprintSlice(number: number, status: parsed, gateRun: gateRun)
  }
}

/// `{"name": "slicing", "slice": 2}`; only `slicing` carries a slice.
private struct StepShape: Codable {
  let name: String
  let slice: Int?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case name, slice
  }

  private static let names = ["started", "surfaced", "slicing", "finished"]

  init(_ step: SprintStep) {
    switch step {
    case .started: (name, slice) = ("started", nil)
    case .surfaced: (name, slice) = ("surfaced", nil)
    case .slicing(let n): (name, slice) = ("slicing", n)
    case .finished: (name, slice) = ("finished", nil)
    }
  }

  init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(decoder, allowed: CodingKeys.allCases.map(\.rawValue))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    name = try c.decode(String.self, forKey: .name)
    slice = try c.decodeIfPresent(Int.self, forKey: .slice)
  }

  func step() throws(SprintRunJSONError) -> SprintStep {
    switch (name, slice) {
    case ("started", nil): return .started
    case ("surfaced", nil): return .surfaced
    case ("finished", nil): return .finished
    case ("slicing", .some(let n)) where n >= 1: return .slicing(n)
    case ("slicing", .some(let n)):
      throw .invalid(field: "step.slice", reason: "\(n) is not a slice number")
    case ("slicing", nil):
      throw .invalid(field: "step.slice", reason: "a slicing step names its last passed slice")
    case (_, .some) where Self.names.contains(name):
      throw .invalid(field: "step.slice", reason: "only a slicing step has a slice")
    default:
      throw .invalid(
        field: "step.name",
        reason: "\(name) is not one of " + Self.names.joined(separator: ", "))
    }
  }
}

private struct AnyKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

/// A key the file format doesn't define fails decoding at that key, so a misspelt field can't
/// read as absent.
private func rejectUnknownKeys(_ decoder: any Decoder, allowed: [String]) throws {
  let container = try decoder.container(keyedBy: AnyKey.self)
  let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
  if let first = unknown.first {
    throw DecodingError.dataCorruptedError(
      forKey: AnyKey(stringValue: first), in: container, debugDescription: "\(first) is not a key")
  }
}
