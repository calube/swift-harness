import Foundation

extension EventSegmentLayout {
  /// A sealed `test.result` segment's rollup, beside its index.
  public static func rollupName(_ sequence: Int) -> String { "" }
}

/// `<seq>.rollup.json`: what 1 sealed `test.result` segment's runs held, so the flaky and slow-test
/// section never decompresses the segment.
public struct TestRollup: Sendable, Equatable, Codable {
  public static let schemaVersion = 1

  /// 1 gate run's results.
  public struct Run: Sendable, Equatable, Codable {
    public let runID: String?
    /// The run's `gate.run` event id, whose payload holds the tree it ran on.
    public let parentID: String?
    /// The run's earliest result.
    public let firstTime: Date
    /// Each result's test, as an index into ``TestRollup/tests``, in the order written.
    public let results: [Int]
    /// Each result's duration, aligned with ``results``.
    public let milliseconds: [Int?]
    /// Positions in ``results`` that failed.
    public let failed: [Int]
    /// Positions in ``results`` that were skipped.
    public let skipped: [Int]
    /// Positions in ``results`` that were known issues that occurred.
    public let expectedFailures: [Int]

    public init(
      runID: String?, parentID: String?, firstTime: Date, results: [Int], milliseconds: [Int?],
      failed: [Int], skipped: [Int], expectedFailures: [Int]
    ) {
      self.runID = runID
      self.parentID = parentID
      self.firstTime = firstTime
      self.results = results
      self.milliseconds = milliseconds
      self.failed = failed
      self.skipped = skipped
      self.expectedFailures = expectedFailures
    }
  }

  public let schemaVersion: Int
  /// Every test id the segment names, each once.
  public let tests: [String]
  public let runs: [Run]

  public init(tests: [String], runs: [Run]) {
    self.schemaVersion = 0
    self.tests = tests
    self.runs = runs
  }

  /// The rollup of `events`' `test.result` events; other kinds are left out.
  public init(results events: [HarnessEvent]) {
    self.schemaVersion = 0
    self.tests = []
    self.runs = []
  }

  /// The rollup of `segment`, a sealed segment's uncompressed lines.
  public static func make(segment: Data) throws(HarnessEventDecodeError) -> TestRollup {
    TestRollup(tests: [], runs: [])
  }

  public func encoded() throws -> Data {
    Data()
  }

  public static func decode(_ data: Data) throws -> TestRollup {
    TestRollup(tests: [], runs: [])
  }
}

/// Every sealed `test.result` segment's rollup in the worktree's store and each imported or unkept
/// store, for the segments a query may match.
public struct TestRollupRead: Sendable, Equatable {
  public let rollups: [TestRollup]
  /// A rollup that was missing or unreadable, rebuilt from its segment; or a segment that didn't
  /// read either.
  public let damage: [EventDamage]

  public init(rollups: [TestRollup], damage: [EventDamage]) {
    self.rollups = rollups
    self.damage = damage
  }

  public static func read(files: any EventStoreFileReading, query: EventQuery) -> TestRollupRead {
    TestRollupRead(rollups: [], damage: [])
  }
}
