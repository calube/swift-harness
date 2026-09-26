import SwiftGateAdapters
import Synchronization

/// A scripted ``SwiftFormatter``: returns the given violations for the paths linted and records
/// every call.
public final class FakeSwiftFormatter: SwiftFormatter {
  private let violations: [FormatViolation]
  private let reformats: Set<String>
  private let failure: SwiftFormatError?
  private let lintCalls = Mutex<[[String]]>([])
  private let formatCalls = Mutex<[String]>([])

  /// - Parameters:
  ///   - violations: reported when their path is among those linted.
  ///   - reformats: paths whose ``format(path:)`` reports a change.
  public init(
    violations: [FormatViolation] = [], reformats: Set<String> = [],
    failure: SwiftFormatError? = nil
  ) {
    self.violations = violations
    self.reformats = reformats
    self.failure = failure
  }

  public var lintedPaths: [[String]] { lintCalls.withLock { $0 } }
  public var formattedPaths: [String] { formatCalls.withLock { $0 } }

  public func lint(paths: [String]) async throws(SwiftFormatError) -> [FormatViolation] {
    lintCalls.withLock { $0.append(paths) }
    if let failure { throw failure }
    let requested = Set(paths)
    return violations.filter { requested.contains($0.path) }
  }

  public func format(path: String) async throws(SwiftFormatError) -> Bool {
    formatCalls.withLock { $0.append(path) }
    if let failure { throw failure }
    return reformats.contains(path)
  }
}
