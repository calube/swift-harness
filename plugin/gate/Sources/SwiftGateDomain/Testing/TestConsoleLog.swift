/// The parts of `swift test` console output the xUnit reports lack: where an assertion failed,
/// what a crash said, and compiler errors when nothing ran. Formats verified against Swift 6.2
/// (fixtures under `Tests/Fixtures/SwiftTest/`).
public struct TestConsoleLog: Sendable, Equatable {
  public struct Location: Sendable, Equatable {
    /// As printed: absolute for XCTest and the compiler, a bare file name for Swift Testing.
    public let file: String
    public let line: Int
    public let message: String
    /// A Swift Testing issue's `↳` and indented continuation lines, which carry what a first line
    /// such as `Issue recorded` leaves out.
    public internal(set) var detail = ""
  }

  /// `<file>:<line>: error: -[<Target>.<Class> <method>] : <message>`, keyed by
  /// `<Target>.<Class>.<method>`.
  public private(set) var xctestFailures: [String: [Location]] = [:]
  /// `<fatal text>` printed while an XCTest case ran, keyed like ``xctestFailures``.
  public private(set) var xctestFatalErrors: [String: String] = [:]
  /// `✘ Test <name> recorded an issue at <File.swift>:<line>:<col>: <message>`, in order.
  public private(set) var swiftTestingIssues: [Location] = []
  /// Swift Testing tests that started and never finished, in start order.
  public private(set) var swiftTestingUnfinished: [String] = []
  /// `Fatal error: …` lines, in order.
  public private(set) var fatalErrors: [String] = []
  /// `<file>:<line>:<col>: error: <message>` from the compiler.
  public private(set) var compilerErrors: [Location] = []
  /// Other `error:` lines (for example `<unknown>:0: error: …`), in order.
  public private(set) var otherErrors: [String] = []
  /// A `#expect`/`#require` macro expansion that fails to compile (for example `try` in a
  /// non-throwing test): `macro expansion #<name>:<line>:<col>: error: <message>`. Its own
  /// location names the macro, not a file, so `file`/`line` come instead from the compiler's
  /// companion `note: expanded code originates here` on the following line when one names a real
  /// path; otherwise they're `nil`.
  public struct MacroExpansionError: Sendable, Equatable {
    public let message: String
    public let file: String?
    public let line: Int?
  }
  public private(set) var macroExpansionErrors: [MacroExpansionError] = []

  public init(stdout: String, stderr: String) {
    var currentXCTest: String?
    var started: [String] = []
    var continuedIssue: Int?
    var pendingMacroExpansionMessage: String?
    for rawLine in (stdout + "\n" + stderr).split(separator: "\n", omittingEmptySubsequences: true)
    {
      let line = String(rawLine)
      if let index = continuedIssue, line.hasPrefix("↳ ") || line.hasPrefix(" ") {
        let text = line.hasPrefix("↳ ") ? String(line.dropFirst(2)) : line
        let detail = swiftTestingIssues[index].detail
        swiftTestingIssues[index].detail = detail.isEmpty ? text : detail + "\n" + text
        continue
      }
      continuedIssue = nil
      if let message = pendingMacroExpansionMessage {
        pendingMacroExpansionMessage = nil
        let note = Self.macroExpansionNote(line)
        macroExpansionErrors.append(
          MacroExpansionError(message: message, file: note?.file, line: note?.line))
        if note != nil { continue }
      }
      if let test = Self.between(line, "Test Case '-[", "]' started.") {
        currentXCTest = Self.xctestKey(test)
      } else if line.hasPrefix("Test Case '-[") {
        currentXCTest = nil
      } else if let failure = Self.xctestFailure(line) {
        xctestFailures[failure.key, default: []].append(failure.location)
      } else if let issue = Self.swiftTestingIssue(line) {
        swiftTestingIssues.append(issue)
        continuedIssue = swiftTestingIssues.count - 1
      } else if line.hasPrefix("◇ Test "), line.hasSuffix(" started.") {
        started.append(String(line.dropFirst("◇ Test ".count).dropLast(" started.".count)))
      } else if line.hasPrefix("✔ Test ") || line.hasPrefix("✘ Test ") || line.hasPrefix("➜ Test ")
      {
        let rest = line.dropFirst("✔ Test ".count)
        if let index = started.firstIndex(where: { rest.hasPrefix($0 + " ") }) {
          started.remove(at: index)
        }
      } else if let message = Self.macroExpansionError(line) {
        pendingMacroExpansionMessage = message
      } else if let error = Self.compilerError(line) {
        compilerErrors.append(error)
      } else if line.contains("error: ") {
        otherErrors.append(line.trimmingCharacters(in: .whitespaces))
      }
      if let range = line.range(of: "Fatal error: ") {
        let text = String(line[range.lowerBound...])
        fatalErrors.append(text)
        if let currentXCTest { xctestFatalErrors[currentXCTest] = text }
      }
    }
    swiftTestingUnfinished = started
  }

  /// `ProbeTests.FailXCTests testDoublesWrong` → `ProbeTests.FailXCTests.testDoublesWrong`.
  static func xctestKey(_ bracketed: String) -> String {
    bracketed.replacingOccurrences(of: " ", with: ".")
  }

  private static func between(_ line: String, _ prefix: String, _ suffix: String) -> String? {
    guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
    return String(line.dropFirst(prefix.count).dropLast(suffix.count))
  }

  private static func xctestFailure(_ line: String) -> (key: String, location: Location)? {
    guard let marker = line.range(of: ": error: -["),
      let close = line.range(of: "] : ", range: marker.upperBound..<line.endIndex)
    else { return nil }
    let head = line[..<marker.lowerBound]
    guard let colon = head.lastIndex(of: ":"), let number = Int(head[head.index(after: colon)...])
    else { return nil }
    let key = xctestKey(String(line[marker.upperBound..<close.lowerBound]))
    return (
      key,
      Location(
        file: String(head[..<colon]), line: number,
        message: String(line[close.upperBound...]))
    )
  }

  private static func swiftTestingIssue(_ line: String) -> Location? {
    guard line.hasPrefix("✘ Test "), let at = line.range(of: " recorded an issue at ") else {
      return nil
    }
    // `<File.swift>:<line>:<column>: <message>`
    let rest = line[at.upperBound...]
    let parts = rest.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
    guard parts.count == 4, let number = Int(parts[1]), Int(parts[2]) != nil else { return nil }
    return Location(
      file: String(parts[0]), line: number,
      message: parts[3].trimmingCharacters(in: .whitespaces))
  }

  private static func compilerError(_ line: String) -> Location? {
    guard line.hasPrefix("/"), let marker = line.range(of: ": error: ") else { return nil }
    let parts = line[..<marker.lowerBound].split(separator: ":")
    guard parts.count == 3, let number = Int(parts[1]), Int(parts[2]) != nil else { return nil }
    return Location(
      file: String(parts[0]), line: number, message: String(line[marker.upperBound...]))
  }

  /// `macro expansion #<name>:<line>:<col>: error: <message>`: the location names the macro, not a
  /// file, so only the message is usable here.
  private static func macroExpansionError(_ line: String) -> String? {
    guard line.hasPrefix("macro expansion "), let marker = line.range(of: ": error: ") else {
      return nil
    }
    return String(line[marker.upperBound...])
  }

  /// The line the compiler prints right after a macro expansion error, when it can name where the
  /// expanded code came from: `` `- <file>:<line>:<col>: note: expanded code originates here``.
  private static func macroExpansionNote(_ line: String) -> (file: String, line: Int)? {
    var rest = Substring(line)
    if rest.hasPrefix("`- ") { rest.removeFirst(3) }
    guard rest.hasPrefix("/"), let marker = rest.range(of: ": note: ") else { return nil }
    let parts = rest[..<marker.lowerBound].split(separator: ":")
    guard parts.count == 3, let number = Int(parts[1]), Int(parts[2]) != nil else { return nil }
    return (String(parts[0]), number)
  }
}
