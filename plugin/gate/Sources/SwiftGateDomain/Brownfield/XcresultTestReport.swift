import Foundation

/// An `xcodebuild` test run read per test: its result bundle's test tree, as
/// `xcresulttool get test-results tests` prints it, turned into the JUnit the baseline keys on.
public enum XcresultTestReport {
  /// 1 `<testcase>` per case, its classname the test bundle and its name `<Suite>/<method>()`;
  /// `nil` when the tree doesn't parse, holds no case, or holds a failure no test owns, such as
  /// a test runner that couldn't launch. Such a run failed as the whole step.
  public static func junit(fromTests data: Data) -> Data? {
    guard let results = try? XcresultTestResults.parse(data), !results.testCases.isEmpty
    else { return nil }
    // Xcode files a runner that couldn't launch as a failed case under `System Failures`, named
    // `<target>-Runner encountered an error`: an id with no `<Suite>/` that names no test.
    let unowned = results.testCases.contains { testCase in
      ![.passed, .skipped, .expectedFailure].contains(testCase.result)
        && !testCase.identifier.contains("/")
    }
    guard !unowned else { return nil }
    var byTarget: [(target: String, cases: [XcresultTestCase])] = []
    for testCase in results.testCases {
      if let index = byTarget.firstIndex(where: { $0.target == testCase.targetName }) {
        byTarget[index].cases.append(testCase)
      } else {
        byTarget.append((testCase.targetName, [testCase]))
      }
    }
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n"
    for (target, cases) in byTarget {
      xml += "<testsuite name=\"\(JUnitReports.escaped(target))\">\n"
      for testCase in cases {
        let attributes =
          "classname=\"\(JUnitReports.escaped(target))\" "
          + "name=\"\(JUnitReports.escaped(testCase.identifier))\""
        switch testCase.result {
        // A result this reader doesn't know is no pass it can vouch for.
        case .failed, .other:
          xml +=
            "<testcase \(attributes)><failure message=\"failed\">"
            + "\(JUnitReports.escaped(testCase.messages.joined(separator: "\n")))"
            + "</failure></testcase>\n"
        case .skipped: xml += "<testcase \(attributes)><skipped/></testcase>\n"
        case .passed, .expectedFailure: xml += "<testcase \(attributes)/>\n"
        }
      }
      xml += "</testsuite>\n"
    }
    xml += "</testsuites>\n"
    return Data(xml.utf8)
  }
}
