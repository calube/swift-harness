import Foundation

/// Go writes no JUnit, but `go test -json` names every test's end, so a Go area's failures can be
/// read per test rather than as the whole step.
public enum GoTestReport {
  /// `command` with `-json` after each `go test`, unless it already asks for it.
  public static func requestingJSON(_ command: String) -> String {
    let words = command.split(separator: " ", omittingEmptySubsequences: false)
    guard !words.contains("-json") else { return command }
    var rewritten: [Substring] = []
    for (index, word) in words.enumerated() {
      rewritten.append(word)
      if word == "test", index > 0, words[index - 1] == "go" { rewritten.append("-json") }
    }
    return rewritten.joined(separator: " ")
  }

  /// A JUnit document of the tests `output`'s `go test -json` events ended, each case's
  /// classname its package; `nil` when `output` holds no failing test, or when a package failed
  /// with no failing test of its own, as a build failure or a `TestMain` exit does, so that
  /// failure stays the whole step's.
  public static func junit(fromJSON output: String) -> Data? {
    var ended: [TestKey: Outcome] = [:]
    var order: [TestKey] = []
    var outputs: [TestKey: String] = [:]
    var failedPackages: Set<String> = []
    var failingPackages: Set<String> = []
    let decoder = JSONDecoder()
    for line in output.split(separator: "\n") where line.hasPrefix("{\"") {
      guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)) else { continue }
      if event.action == "build-fail" { return nil }
      guard let package = event.package else { continue }
      guard let test = event.test else {
        if event.action == "fail" { failedPackages.insert(package) }
        continue
      }
      let key = TestKey(package: package, test: test)
      let outcome: Outcome
      switch event.action {
      case "output":
        outputs[key, default: ""] += event.output ?? ""
        continue
      case "pass": outcome = .passed
      case "skip": outcome = .skipped
      case "fail":
        outcome = .failed
        failingPackages.insert(package)
      default: continue
      }
      if ended.updateValue(outcome, forKey: key) == nil { order.append(key) }
    }
    guard !failingPackages.isEmpty, failedPackages.isSubset(of: failingPackages) else {
      return nil
    }
    var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n"
    for package in Set(order.map(\.package)).sorted() {
      xml += "<testsuite name=\"\(JUnitReports.escaped(package))\">\n"
      for key in order where key.package == package {
        let attributes =
          "classname=\"\(JUnitReports.escaped(package))\" name=\"\(JUnitReports.escaped(key.test))\""
        switch ended[key] {
        case .failed:
          xml +=
            "<testcase \(attributes)><failure message=\"failed\">"
            + "\(JUnitReports.escaped(outputs[key] ?? ""))</failure></testcase>\n"
        case .skipped: xml += "<testcase \(attributes)><skipped/></testcase>\n"
        case .passed, nil: xml += "<testcase \(attributes)/>\n"
        }
      }
      xml += "</testsuite>\n"
    }
    xml += "</testsuites>\n"
    return Data(xml.utf8)
  }

  private struct TestKey: Hashable {
    let package: String
    let test: String
  }

  private enum Outcome {
    case passed, failed, skipped
  }

  private struct Event: Decodable {
    let action: String
    let package: String?
    let test: String?
    let output: String?

    enum CodingKeys: String, CodingKey {
      case action = "Action"
      case package = "Package"
      case test = "Test"
      case output = "Output"
    }
  }
}
