import Foundation

/// What brownfield prove records for each changed test it ran, beside its findings.
public enum BrownfieldProofs {
  /// 1 ``ProvedTest`` per id whose reverted run says something about it. A time-out says
  /// nothing, and neither does a crash of the whole `test` command, which no test owns.
  /// - Parameters:
  ///   - area: the area's name, as each result's target.
  ///   - outcomes: each id with the reverted run that selected it.
  ///   - whole: the run was the area's whole `test` command, which can't attribute a crash.
  ///   - proofBase: the commit the source was reverted to.
  public static func proved(
    area: String, outcomes: [(AreaTestID, AreaCommandOutcome)], whole: Bool, proofBase: String
  ) -> [ProvedTest] {
    let ids = outcomes.map(\.0)
    return outcomes.compactMap { id, outcome in
      let result: (ProveResultOutcome, ProveAssertion?)
      switch outcome {
      case .passed:
        result = (.passesReverted, nil)
      case .failed(_, let tail, let junit):
        result = (
          .proven, AreaFailureLocator.firstFailure(of: id, among: ids, output: tail, junit: junit)
        )
      case .crashed:
        guard !whole else { return nil }
        result = (.crashed, nil)
      case .timedOut:
        return nil
      }
      return ProvedTest(
        test: id.name, target: area, outcome: result.0, proofBase: proofBase,
        assertion: result.1)
    }
  }
}

/// Where an area's reverted run first failed inside 1 changed test's file, read from the runner's
/// JUnit failure elements and then its output. Only a location and an assertion form leave this
/// type: never a message or a source line.
public enum AreaFailureLocator {
  /// - Parameters:
  ///   - id: the test whose failure is wanted.
  ///   - ids: every id the run selected; another id's lines in the same file aren't `id`'s.
  ///   - output: the run's output tail.
  ///   - junit: the run's JUnit report, when it wrote one.
  /// - Returns: `nil` when neither names a line of `id`'s file.
  public static func firstFailure(
    of id: AreaTestID, among ids: [AreaTestID], output: String, junit: Data?
  ) -> ProveAssertion? {
    // A sibling starting later in the same file owns the lines from its start on.
    let end = ids.filter { $0.file == id.file && $0.line > id.line }.map(\.line).min()
    let owns: (Int) -> Bool =
      ids.contains { $0 != id && $0.file == id.file }
      ? { line in line >= id.line && end.map { line < $0 } ?? true } : { _ in true }
    let texts = (junit.map(JUnitFailureText.read) ?? []) + [output]
    for text in texts {
      for line in text.split(separator: "\n") {
        for location in locations(in: line)
        where names(location.path, id.file) && owns(location.line) {
          return ProveAssertion(file: id.file, line: location.line, kind: kind(of: line))
        }
      }
    }
    return nil
  }

  /// `path:line` tokens, the form every runner's failure frames share.
  private static func locations(in line: Substring) -> [(path: Substring, line: Int)] {
    line.matches(of: /([^\s"'()\[\]<>,=:]+):(\d+)/).compactMap { match in
      Int(match.output.2).map { (match.output.1, $0) }
    }
  }

  /// Whether `printed` names `file`: one path's components end the other's, as a runner prints
  /// paths relative to wherever it ran, or absolute.
  private static func names(_ printed: Substring, _ file: String) -> Bool {
    func components<S: StringProtocol>(_ path: S) -> [Substring] {
      path.split(separator: "/").map { Substring($0) }.filter { $0 != "." }
    }
    let printed = components(printed)
    let file = components(file)
    guard let last = file.last, printed.last == last else { return false }
    let count = min(printed.count, file.count)
    return printed.suffix(count) == file.suffix(count)
  }

  private static func kind(of line: Substring) -> ProveAssertionKind {
    if line.contains("XCTAssert") || line.contains("XCTFail") { return .xctAssert }
    if line.contains("Expectation failed") { return .expect }
    return .other
  }
}

/// The text of a JUnit report's `<failure>` and `<error>` elements, in document order.
private final class JUnitFailureText: NSObject, XMLParserDelegate {
  private var texts: [String] = []
  private var current: String?

  static func read(_ data: Data) -> [String] {
    let delegate = JUnitFailureText()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.texts
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String] = [:]
  ) {
    if elementName == "failure" || elementName == "error" { current = "" }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    current?.append(string)
  }

  func parser(_ parser: XMLParser, foundCDATA block: Data) {
    current?.append(String(decoding: block, as: UTF8.self))
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName: String?
  ) {
    if elementName == "failure" || elementName == "error", let text = current {
      texts.append(text)
      current = nil
    }
  }
}
