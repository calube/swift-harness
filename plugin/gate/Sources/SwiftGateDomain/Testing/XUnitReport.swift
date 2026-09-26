import Foundation

/// One `<testcase>` from a `swift test --xunit-output` report.
public struct XUnitTestCase: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    case passed
    /// XCTest writes the placeholder message `failure`; Swift Testing writes the issue text.
    case failed(message: String)
    /// Only Swift Testing reports skips. Under `--parallel`, SwiftPM's XCTest report records an
    /// `XCTSkip` as a pass, so XCTest skips are invisible to these rules.
    case skipped(reason: String?)
  }

  /// `<TestTarget>.<Suite>` for suites and XCTest classes.
  public let className: String
  public let name: String
  public let outcome: Outcome

  public init(className: String, name: String, outcome: Outcome) {
    self.className = className
    self.name = name
    self.outcome = outcome
  }

  /// The test target (module) the case belongs to: `className` up to its first `.`.
  public var targetName: String {
    className.split(separator: ".", maxSplits: 1).first.map(String.init) ?? className
  }

  public var isExecuted: Bool {
    if case .skipped = outcome { return false }
    return true
  }
}

public struct XUnitParseError: Error, Sendable, Equatable {
  public let detail: String
}

public enum XUnitReport {
  /// Parses a whole report. A truncated or malformed document (a test process that crashed while
  /// writing it) throws rather than yielding the cases read so far.
  public static func parse(_ data: Data) throws(XUnitParseError) -> [XUnitTestCase] {
    let delegate = XUnitParserDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse(), delegate.sawRoot, delegate.openElements.isEmpty else {
      throw XUnitParseError(
        detail: parser.parserError.map { "\($0.localizedDescription)" }
          ?? "incomplete document")
    }
    return delegate.cases
  }
}

private final class XUnitParserDelegate: NSObject, XMLParserDelegate {
  var cases: [XUnitTestCase] = []
  var sawRoot = false
  var openElements: [String] = []

  private var current: (className: String, name: String)?
  private var outcome: XUnitTestCase.Outcome = .passed
  private var skipText: String?

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    openElements.append(elementName)
    switch elementName {
    case "testsuites": sawRoot = true
    case "testcase":
      current = (attributes["classname"] ?? "", attributes["name"] ?? "")
      outcome = .passed
    case "failure", "error":
      // The first failure is the one the report is about; later ones repeat the test's fate.
      if case .failed = outcome { break }
      outcome = .failed(message: attributes["message"] ?? "")
    case "skipped":
      skipText = ""
    default: break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if skipText != nil { skipText? += string }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    openElements.removeLast()
    switch elementName {
    case "skipped":
      let reason = skipText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      outcome = .skipped(reason: reason.isEmpty ? nil : reason)
      skipText = nil
    case "testcase":
      if let current {
        cases.append(
          XUnitTestCase(className: current.className, name: current.name, outcome: outcome))
      }
      current = nil
    default: break
    }
  }
}
