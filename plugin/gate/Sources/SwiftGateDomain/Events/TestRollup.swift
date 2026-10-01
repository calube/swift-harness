import Foundation

extension EventSegmentLayout {
  /// A sealed `test.result` segment's rollup, beside its index.
  public static func rollupName(_ sequence: Int) -> String { "\(sequence).rollup.json" }
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

    private enum CodingKeys: String, CodingKey {
      case runID, parentID, firstTime, results, failed, skipped, expectedFailures
      case milliseconds = "ms"
    }
  }

  public let schemaVersion: Int
  /// Every test id the segment names, each once.
  public let tests: [String]
  public let runs: [Run]

  public init(tests: [String], runs: [Run]) {
    self.schemaVersion = Self.schemaVersion
    self.tests = tests
    self.runs = runs
  }

  /// The rollup of `events`' `test.result` events, 1 run per `gate.run` parent, in the order
  /// first seen; other kinds are left out.
  public init(results events: [HarnessEvent]) {
    struct Building {
      let runID: String?
      let parentID: String?
      var firstTime: Date
      var results: [Int] = []
      var milliseconds: [Int?] = []
      var failed: [Int] = []
      var skipped: [Int] = []
      var expectedFailures: [Int] = []
    }
    var tests: [String] = []
    var testIndex: [String: Int] = [:]
    var runs: [Building] = []
    var runIndex: [RunKey: Int] = [:]
    for event in events {
      guard case .testResult(let result) = event.payload else { continue }
      let key = RunKey(parentID: event.parentID, runID: event.runID)
      let run: Int
      if let existing = runIndex[key] {
        run = existing
        runs[run].firstTime = min(runs[run].firstTime, event.time)
      } else {
        run = runs.count
        runIndex[key] = run
        runs.append(Building(runID: event.runID, parentID: event.parentID, firstTime: event.time))
      }
      let test: Int
      if let existing = testIndex[result.test] {
        test = existing
      } else {
        test = tests.count
        testIndex[result.test] = test
        tests.append(result.test)
      }
      let position = runs[run].results.count
      runs[run].results.append(test)
      runs[run].milliseconds.append(result.milliseconds)
      switch result.outcome {
      case .passed: break
      case .failed: runs[run].failed.append(position)
      case .skipped: runs[run].skipped.append(position)
      case .expectedFailure: runs[run].expectedFailures.append(position)
      }
    }
    self.init(
      tests: tests,
      runs: runs.map {
        Run(
          runID: $0.runID, parentID: $0.parentID, firstTime: $0.firstTime, results: $0.results,
          milliseconds: $0.milliseconds, failed: $0.failed, skipped: $0.skipped,
          expectedFailures: $0.expectedFailures)
      })
  }

  /// The rollup of `segment`, a sealed segment's uncompressed lines. Fails on a line that doesn't
  /// read or a torn last line, as its index does.
  public static func make(segment: Data) throws(HarnessEventDecodeError) -> TestRollup {
    let read = try HarnessEventJSON.decode(segment)
    if read.tornLastLine {
      let lines = segment.split(separator: UInt8(ascii: "\n")).count
      throw HarnessEventDecodeError(line: lines, reason: .invalid("torn last line"))
    }
    return TestRollup(results: read.events)
  }

  private struct RunKey: Hashable {
    let parentID: String?
    let runID: String?
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, tests, runs
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(date.formatted(HarnessEventJSON.timeFormat))
    }
    return try encoder.encode(self)
  }

  /// A rollup whose every index and position points inside it; anything else fails, so a corrupt
  /// rollup is rebuilt rather than read.
  public static func decode(_ data: Data) throws -> TestRollup {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let date = try? Date(text, strategy: HarnessEventJSON.timeFormat) else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "`\(text)` isn't an ISO 8601 time")
      }
      return date
    }
    let rollup = try decoder.decode(TestRollup.self, from: data)
    func corrupt(_ why: String) -> DecodingError {
      DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: why))
    }
    guard rollup.schemaVersion == schemaVersion else {
      throw corrupt("unsupported schemaVersion \(rollup.schemaVersion)")
    }
    for run in rollup.runs {
      guard run.milliseconds.count == run.results.count else {
        throw corrupt(
          "run \(run.runID ?? "?") has \(run.milliseconds.count) durations for \(run.results.count) results"
        )
      }
      guard run.results.allSatisfy({ rollup.tests.indices.contains($0) }) else {
        throw corrupt("run \(run.runID ?? "?") names a test the rollup doesn't hold")
      }
      for positions in [run.failed, run.skipped, run.expectedFailures] {
        guard positions.allSatisfy({ run.results.indices.contains($0) }) else {
          throw corrupt("run \(run.runID ?? "?") marks a result it doesn't hold")
        }
      }
    }
    return rollup
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

  /// The rollups of every sealed segment whose index doesn't rule it out of `query`. A rollup
  /// that's missing or doesn't decode is rebuilt from its segment in memory and listed as damage.
  /// Never opens a segment whose rollup reads.
  public static func read(files: any EventStoreFileReading, query: EventQuery) -> TestRollupRead {
    if let kinds = query.kinds, !kinds.contains(.testResult) {
      return TestRollupRead(rollups: [], damage: [])
    }
    var damage: [EventDamage] = []
    func unreadable(_ path: String, _ detail: String) {
      damage.append(EventDamage(file: path, line: nil, kind: .unreadableFile, detail: detail))
    }
    var stores = [RunLayout.eventsDirectory]
    for parent in ["imported", "unkept"].map({ "\(RunLayout.eventsDirectory)/\($0)" }) {
      do throws(EventStoreFileError) {
        stores += try files.list(parent).filter { !$0.hasPrefix(".") }.map { "\(parent)/\($0)" }
      } catch {
        unreadable(error.path, error.reason)
      }
    }
    var rollups: [TestRollup] = []
    for store in stores {
      let directory = "\(store)/sealed/\(HarnessEventStream.test.rawValue)"
      var segments: [Int: Set<String>] = [:]
      do throws(EventStoreFileError) {
        for name in try files.list(directory) {
          switch EventSegmentLayout.file(named: name) {
          case .plain(let sequence), .compressed(let sequence), .index(let sequence):
            segments[sequence, default: []].insert(name)
          case nil: continue
          }
        }
      } catch {
        unreadable(error.path, error.reason)
      }
      for (sequence, names) in segments.sorted(by: { $0.key < $1.key }) {
        let plain = EventSegmentLayout.plainName(sequence)
        let compressed = EventSegmentLayout.compressedName(sequence)
        guard names.contains(plain) || names.contains(compressed) else { continue }
        if names.contains(EventSegmentLayout.indexName(sequence)),
          let index = try? files.read("\(directory)/\(EventSegmentLayout.indexName(sequence))")
            .flatMap({ try? EventSegmentIndex.decode($0) }),
          !query.mayMatch(index)
        {
          // An index that doesn't read is the event reader's damage; the segment is kept.
          continue
        }
        let rollupPath = "\(directory)/\(EventSegmentLayout.rollupName(sequence))"
        let why: String
        do {
          if let data = try files.read(rollupPath) {
            rollups.append(try TestRollup.decode(data))
            continue
          }
          why = "missing"
        } catch {
          why = "\(error)"
        }
        do {
          let segment = try Self.segment(
            files: files, plain: names.contains(plain) ? "\(directory)/\(plain)" : nil,
            compressed: "\(directory)/\(compressed)")
          rollups.append(try TestRollup.make(segment: segment))
          unreadable(rollupPath, "\(why); rebuilt from its segment")
        } catch {
          unreadable(rollupPath, "\(why), and its segment didn't read: \(error)")
        }
      }
    }
    return TestRollupRead(rollups: rollups, damage: damage)
  }

  /// A segment's lines: the plain file while it's there, else the decompressed one.
  private static func segment(
    files: any EventStoreFileReading, plain: String?, compressed: String
  ) throws -> Data {
    if let plain, let data = try files.read(plain) { return data }
    guard let packed = try files.read(compressed) else {
      throw EventStoreFileError(path: compressed, reason: "gone")
    }
    return try (packed as NSData).decompressed(using: .lzfse) as Data
  }
}
