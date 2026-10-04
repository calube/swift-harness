import Foundation

/// How an area command's `/bin/sh` ended, as the process runner saw it.
public enum AreaProcessEnd: Sendable, Equatable {
  case exited(Int32)
  case signaled(Int32)
}

/// The totals of a JUnit XML report, counted from its `<testcase>` elements because runners
/// disagree on where they put the summary attributes.
public struct JUnitCounts: Sendable, Equatable {
  public let tests: Int
  /// Cases holding a `<failure>` or an `<error>`.
  public let failures: Int
  public let skipped: Int

  public init(tests: Int, failures: Int, skipped: Int) {
    self.tests = tests
    self.failures = failures
    self.skipped = skipped
  }
}

/// Turns an area command's end, its combined output and its JUnit report into an outcome. A
/// crash wins over every other reading: a runner that survives its test process's death often
/// exits 1 and writes a report that reads as a pass.
public enum AreaOutcomeReading {
  public static let tailLineCount = 40

  public static func outcome(end: AreaProcessEnd, output: String, junit: Data?)
    -> AreaCommandOutcome
  {
    let exit: Int32
    switch end {
    case .signaled(let signal): return .crashed(signal: signal, tail: tail(output))
    case .exited(let status): exit = status
    }
    // `/bin/sh` reports a child killed by signal N as status 128 + N.
    if (129...192).contains(exit) { return .crashed(signal: exit - 128, tail: tail(output)) }
    if exit == 0 { return .passed }
    if let crash = crashMarker(in: output) {
      return .crashed(signal: crash.signal, tail: tail(output))
    }
    return .failed(exit: exit, tail: tail(output), junit: junit)
  }

  public static func timedOut(output: String) -> AreaCommandOutcome {
    .timedOut(tail: tail(output))
  }

  /// The last ``tailLineCount`` lines of `output`.
  public static func tail(_ output: String) -> String {
    var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines.suffix(tailLineCount).joined(separator: "\n")
  }

  /// `nil` when `data` is not a complete JUnit document.
  public static func junitCounts(_ data: Data) -> JUnitCounts? {
    let delegate = JUnitCountingDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.sawSuite, delegate.depth == 0 else { return nil }
    return JUnitCounts(
      tests: delegate.tests, failures: delegate.failures, skipped: delegate.skipped)
  }

  private struct CrashMarker {
    /// `nil` when the runner named the death but no signal.
    let signal: Int32?
  }

  /// A runner that outlives its test process prints that death in its own words.
  private static func crashMarker(in output: String) -> CrashMarker? {
    let signalPatterns = [
      /\(signal: (\d+), SIG[A-Z]+/,  // cargo: the test binary's death
      /Exited with unexpected signal code (\d+)/,  // SwiftPM under --parallel
    ]
    for pattern in signalPatterns {
      if let match = output.firstMatch(of: pattern), let signal = Int32(match.1) {
        return CrashMarker(signal: signal)
      }
    }
    if unsignalledMarkers.contains(where: output.contains) || goTestLeftRunning(output) {
      return CrashMarker(signal: nil)
    }
    return nil
  }

  private static let unsignalledMarkers = [
    "----- Native stack trace -----",  // node's abort handler, after pnpm turned it into status 1
    "finished with non-zero exit value",  // Gradle's test executor exited
    "The forked VM terminated without properly saying goodbye",  // Surefire's fork exited
    "Fatal Python error:",
    ": [BUG] ",  // Ruby's crash report, after `path:line`
  ]

  /// `go test -json`: a test that started and never passed, failed or skipped means its binary
  /// exited under it, as `os.Exit` or a fatal runtime error does.
  private static func goTestLeftRunning(_ output: String) -> Bool {
    struct Event: Decodable {
      let action: String
      let test: String?
      enum CodingKeys: String, CodingKey {
        case action = "Action"
        case test = "Test"
      }
    }
    var running: Set<String> = []
    let decoder = JSONDecoder()
    for line in output.split(separator: "\n") where line.hasPrefix("{\"") {
      guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)),
        let test = event.test
      else { continue }
      switch event.action {
      case "run": running.insert(test)
      case "pass", "fail", "skip": running.remove(test)
      default: break
      }
    }
    return !running.isEmpty
  }
}

private final class JUnitCountingDelegate: NSObject, XMLParserDelegate {
  var tests = 0
  var failures = 0
  var skipped = 0
  var sawSuite = false
  var depth = 0

  private var caseFailed = false
  private var caseSkipped = false

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    depth += 1
    switch elementName {
    case "testsuite", "testsuites": sawSuite = true
    case "testcase":
      caseFailed = false
      caseSkipped = false
    case "failure", "error": caseFailed = true
    case "skipped": caseSkipped = true
    default: break
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    depth -= 1
    guard elementName == "testcase" else { return }
    tests += 1
    if caseFailed {
      failures += 1
    } else if caseSkipped {
      skipped += 1
    }
  }
}
