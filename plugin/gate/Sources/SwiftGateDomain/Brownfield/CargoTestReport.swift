import Foundation

/// cargo writes no JUnit, but libtest names every test's result, so a cargo area's failures can
/// be read per test rather than as the whole step.
public enum CargoTestReport {
  /// A JUnit document of the tests `output`'s libtest results name, each case's classname the
  /// test target cargo ran, so 2 targets' tests of 1 name stay apart. `nil` when `output` holds
  /// no failing test, or anything failed that no test result accounts for: a compile error, a
  /// target with no result line, a target cargo failed after its tests passed, or a result line
  /// counting more failures than the lines naming them. Each of those stays the whole step's.
  ///
  /// `output` is stdout with stderr folded in, as the area runner reads it, so cargo's
  /// `Running` lines sit before the results of the target they name.
  public static func junit(fromOutput output: String) -> Data? {
    var targets: [Target] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("error: could not compile") { return nil }
      if let name = targetName(line) {
        targets.append(Target(name: name))
        continue
      }
      if line.hasPrefix("error: test failed") || line.hasPrefix("error: doctest failed") {
        // cargo names the target it gave up on right after that target's results.
        guard let last = targets.last, last.result == .failed else { return nil }
        continue
      }
      if let match = line.wholeMatch(of: /test (.+) \.\.\. (ok|FAILED|ignored.*)/) {
        guard !targets.isEmpty, targets[targets.count - 1].result == nil else { return nil }
        let outcome: Outcome =
          switch match.2 {
          case "ok": .passed
          case "FAILED": .failed
          default: .skipped
          }
        targets[targets.count - 1].cases.append((String(match.1), outcome))
        continue
      }
      if let match = line.firstMatch(of: /^test result: (ok|FAILED)\. \d+ passed; (\d+) failed;/) {
        guard !targets.isEmpty, targets[targets.count - 1].result == nil,
          let failed = Int(match.2)
        else { return nil }
        targets[targets.count - 1].result = match.1 == "ok" ? .passed : .failed
        targets[targets.count - 1].reportedFailures = failed
      }
    }
    var failing = 0
    for target in targets {
      let named = target.cases.count(where: { $0.outcome == .failed })
      guard target.result != nil, named == target.reportedFailures else { return nil }
      failing += named
    }
    guard failing > 0 else { return nil }
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n"
    for target in targets {
      let classname = JUnitReports.escaped(target.name)
      xml += "<testsuite name=\"\(classname)\">\n"
      for (name, outcome) in target.cases {
        let attributes = "classname=\"\(classname)\" name=\"\(JUnitReports.escaped(name))\""
        switch outcome {
        case .failed:
          xml += "<testcase \(attributes)><failure message=\"FAILED\"/></testcase>\n"
        case .skipped: xml += "<testcase \(attributes)><skipped/></testcase>\n"
        case .passed: xml += "<testcase \(attributes)/>\n"
        }
      }
      xml += "</testsuite>\n"
    }
    return Data((xml + "</testsuites>\n").utf8)
  }

  private enum Outcome {
    case passed, failed, skipped
  }

  private struct Target {
    let name: String
    var cases: [(name: String, outcome: Outcome)] = []
    /// `nil` until the target's `test result:` line.
    var result: Outcome?
    var reportedFailures = 0
  }

  /// `Running unittests src/lib.rs (target/debug/deps/core-1a2b3c)` names the target
  /// `unittests src/lib.rs (core)`, without the build hash that changes between trees;
  /// `Doc-tests core` names itself.
  private static func targetName(_ line: String) -> String? {
    if line.hasPrefix("Doc-tests ") { return line }
    guard let match = line.wholeMatch(of: /Running (.+) \((.+)\)/) else { return nil }
    var binary = String(match.2.split(separator: "/").last ?? "")
    if let dash = binary.lastIndex(of: "-"),
      binary[binary.index(after: dash)...].allSatisfy(\.isHexDigit)
    {
      binary = String(binary[..<dash])
    }
    return "\(match.1) (\(binary))"
  }
}
