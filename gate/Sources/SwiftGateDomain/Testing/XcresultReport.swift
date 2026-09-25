import Foundation

/// One test case from `xcresulttool get test-results tests` (Xcode 26.2, schema 0.1.0).
public struct XcresultTestCase: Sendable, Equatable {
  public enum Result: Sendable, Equatable {
    case passed
    case failed
    case skipped
    /// `XCTExpectFailure` / `withKnownIssue` whose issue occurred.
    case expectedFailure
    /// A value this reader does not know, such as `unknown`.
    case other(String)
  }

  /// `<Suite>/<name>()`, as `-only-testing` accepts it.
  public let identifier: String
  /// The test bundle (target) that holds the case.
  public let targetName: String
  public let result: Result
  /// The case's `Failure Message` nodes in report order. Xcode files skip reasons and crash
  /// descriptions here too.
  public let messages: [String]
  /// The case ran in a UI test bundle (an XCUITest), not a unit test bundle.
  public let isUITest: Bool

  public init(
    identifier: String, targetName: String, result: Result, messages: [String],
    isUITest: Bool = false
  ) {
    self.identifier = identifier
    self.targetName = targetName
    self.result = result
    self.messages = messages
    self.isUITest = isUITest
  }
}

/// The parsed test tree of one result bundle.
public struct XcresultTestResults: Sendable, Equatable {
  /// Whether any destination the tests were meant to run on was resolved. An unresolved
  /// destination is recorded as a device with an empty `deviceId`.
  public let ranOnDevice: Bool
  public let testCases: [XcresultTestCase]

  public static func parse(_ data: Data) throws(XcresultParseError) -> XcresultTestResults {
    let raw: RawTestResults
    do {
      raw = try JSONDecoder().decode(RawTestResults.self, from: data)
    } catch {
      throw XcresultParseError(detail: "test results: \(error)")
    }
    var cases: [XcresultTestCase] = []
    for node in raw.testNodes { collect(node, target: nil, isUITest: false, into: &cases) }
    return XcresultTestResults(
      ranOnDevice: raw.devices.contains { !$0.deviceId.isEmpty }, testCases: cases)
  }

  private static func collect(
    _ node: RawNode, target: String?, isUITest: Bool, into cases: inout [XcresultTestCase]
  ) {
    switch node.nodeType {
    case "Unit test bundle", "UI test bundle":
      for child in node.children ?? [] {
        collect(
          child, target: node.name, isUITest: node.nodeType == "UI test bundle", into: &cases)
      }
    case "Test Case":
      cases.append(
        XcresultTestCase(
          identifier: node.nodeIdentifier ?? node.name, targetName: target ?? "",
          result: result(node.result), messages: failureMessages(node), isUITest: isUITest))
    default:
      for child in node.children ?? [] {
        collect(child, target: target, isUITest: isUITest, into: &cases)
      }
    }
  }

  /// Parameterized and repeated cases nest their messages under argument or run nodes.
  private static func failureMessages(_ node: RawNode) -> [String] {
    (node.children ?? []).flatMap { child in
      child.nodeType == "Failure Message" ? [child.name] : failureMessages(child)
    }
  }

  private static func result(_ raw: String?) -> XcresultTestCase.Result {
    switch raw {
    case "Passed": .passed
    case "Failed": .failed
    case "Skipped": .skipped
    case "Expected Failure": .expectedFailure
    default: .other(raw ?? "missing")
    }
  }

  private struct RawTestResults: Decodable {
    let devices: [RawDevice]
    let testNodes: [RawNode]
  }

  private struct RawDevice: Decodable {
    let deviceId: String
  }

  private struct RawNode: Decodable {
    let name: String
    let nodeType: String
    let nodeIdentifier: String?
    let result: String?
    let children: [RawNode]?
  }
}

/// Errors from `xcresulttool get build-results`: why a test action built nothing to run.
public struct XcresultBuildResults: Sendable, Equatable {
  public struct Issue: Sendable, Equatable {
    public let message: String
    /// Absolute path of the file the compiler blamed, when it named one.
    public let file: String?
    /// 1-based.
    public let line: Int?
  }

  public let errors: [Issue]

  public static func parse(_ data: Data) throws(XcresultParseError) -> XcresultBuildResults {
    let raw: RawBuildResults
    do {
      raw = try JSONDecoder().decode(RawBuildResults.self, from: data)
    } catch {
      throw XcresultParseError(detail: "build results: \(error)")
    }
    return XcresultBuildResults(
      errors: raw.errors.map { error in
        let (file, line) = location(error.sourceURL)
        return Issue(message: error.message, file: file, line: line)
      })
  }

  /// `file:///<path>#…&StartingLineNumber=<0-based>&…`.
  private static func location(_ sourceURL: String?) -> (String?, Int?) {
    guard let sourceURL, let components = URLComponents(string: sourceURL),
      components.scheme == "file"
    else { return (nil, nil) }
    var fields: [String: String] = [:]
    for pair in (components.fragment ?? "").split(separator: "&") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
    }
    let line = fields["StartingLineNumber"].flatMap { Int($0) }.map { $0 + 1 }
    return (components.path, line)
  }

  private struct RawBuildResults: Decodable {
    let errors: [RawIssue]
  }

  private struct RawIssue: Decodable {
    let message: String
    let sourceURL: String?
  }
}

public struct XcresultParseError: Error, Sendable, Equatable {
  public let detail: String
}
