import CryptoKit
import Foundation

/// What `prove` found for 1 changed test it ran, before its record writes it as a `prove.result`.
public struct ProvedTest: Sendable, Equatable {
  /// The id `test.result` gives the same test, so the two join.
  public let test: String
  public let target: String
  public let outcome: ProveResultOutcome
  /// The commit the source was reverted to in the run that decided ``outcome``.
  public let proofBase: String?
  public let assertion: ProveAssertion?

  public init(
    test: String, target: String, outcome: ProveResultOutcome, proofBase: String?,
    assertion: ProveAssertion?
  ) {
    self.test = test
    self.target = target
    self.outcome = outcome
    self.proofBase = proofBase
    self.assertion = assertion
  }

  /// `test`'s outcome in 1 reverted run that `judgement` judged; `nil` when the run says nothing
  /// about it, so an earlier run's outcome doesn't stand in for it.
  public static func outcome(
    of test: ChangedTest, run: SelectedTestRun, judgement: ChangedTestJudgement
  ) -> ProveResultOutcome? {
    switch run {
    case .reported(let outcomes):
      switch outcomes[test] {
      case .failed: .proven
      case .passed: .passesReverted
      case .skipped: .skipped
      case nil: nil
      }
    case .buildFailed:
      ProofRules.compileOnly([test], in: judgement).isEmpty ? nil : .compileOnly
    case .crashed: .crashed
    case .noEvidence: nil
    }
  }
}

extension ProvedTest: Codable {}

extension ProveResultEvent {
  public init(_ proved: ProvedTest) {
    // The payload guard would drop the whole event; a hash keeps the result and still joins runs.
    let hashed = EventPayloadGuard.rejection(inJSON: proved.test) != nil
    self.init(
      test: hashed
        ? "sha256:"
          + SHA256.hash(data: Data(proved.test.utf8))
          .map { String(format: "%02x", $0) }.joined()
        : proved.test,
      testHashed: hashed, target: proved.target, outcome: proved.outcome,
      proofBase: proved.proofBase, assertion: proved.assertion)
  }
}

/// Where a reverted run first failed for 1 changed test, read from its console output. Only the
/// location and the assertion form leave this type: never the message or the source.
public enum ProveAssertionLocator {
  /// - Parameter sourceLine: the text of a repository-relative file's line, used only to tell
  ///   `#require` from `#expect`, which Swift Testing reports alike.
  /// - Returns: `nil` when the run printed no failure inside the test, or its file is not under
  ///   the run's repository root.
  public static func firstFailure(
    of test: ChangedTest, in evidence: HostTestEvidence, sourceLine: (String, Int) -> String?
  ) -> ProveAssertion? {
    let log = TestConsoleLog(stdout: evidence.stdout, stderr: evidence.stderr)
    let found: ProveAssertion?
    switch test.framework {
    case .xcTest:
      let key = TestConsoleLog.xctestKey(
        ([test.target] + test.suites).joined(separator: ".") + " " + test.function)
      found = log.xctestFailures[key]?.first.flatMap { failure in
        relative(failure.file, to: evidence.repositoryRoot).map {
          ProveAssertion(file: $0, line: failure.line, kind: xctestKind(failure.message))
        }
      }
    case .swiftTesting:
      // Swift Testing prints a bare file name, so only an issue inside the test's own lines is
      // known to be its own.
      let name = test.file.split(separator: "/").last.map(String.init) ?? test.file
      found = log.swiftTestingIssues.first {
        $0.file == name && (test.line...test.lastLine).contains($0.line)
      }.map { issue in
        let kind: ProveAssertionKind
        if issue.message.hasPrefix("Expectation failed") {
          kind =
            sourceLine(test.file, issue.line)?.contains("#require") == true ? .require : .expect
        } else {
          kind = .other
        }
        return ProveAssertion(file: test.file, line: issue.line, kind: kind)
      }
    }
    guard let found, !found.file.hasPrefix("/"), !found.file.hasPrefix("~"),
      EventPayloadGuard.rejection(inJSON: found.file) == nil
    else { return nil }
    return found
  }

  private static func xctestKind(_ message: String) -> ProveAssertionKind {
    message.hasPrefix("XCT") || message.hasPrefix("failed - ") ? .xctAssert : .other
  }

  private static func relative(_ path: String, to root: String) -> String? {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    guard path.hasPrefix(prefix) else { return nil }
    return String(path.dropFirst(prefix.count))
  }
}
