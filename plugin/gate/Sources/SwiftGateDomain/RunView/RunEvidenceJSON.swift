import Foundation

/// A run's JSON evidence as a report carries it: no string names a machine path. A path inside
/// the run becomes relative to the run's directory; any other absolute path keeps only its last
/// component.
public enum RunEvidenceJSON {
  /// Whether a report rewrites a carried file of this name rather than copying its bytes.
  public static func rewrites(_ fileName: String) -> Bool {
    fileName.hasSuffix(".json") || fileName.hasSuffix(".ndjson")
  }

  /// `data`, a JSON or NDJSON file of run `runID`, with every absolute path in its strings
  /// rewritten; `nil` when it doesn't parse, so the caller copies it as it is.
  public static func relativized(_ data: Data, runID: String) -> Data? {
    let marker = "/runs/\(runID)/"
    if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
      return try? JSONSerialization.data(
        withJSONObject: rewritten(object, marker: marker),
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }
    var lines: [Data] = []
    for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
      guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
        let out = try? JSONSerialization.data(
          withJSONObject: rewritten(object, marker: marker),
          options: [.sortedKeys, .withoutEscapingSlashes])
      else { return nil }
      lines.append(out)
    }
    guard !lines.isEmpty else { return nil }
    return lines.reduce(into: Data()) { all, line in
      all.append(line)
      all.append(UInt8(ascii: "\n"))
    }
  }

  private static func rewritten(_ value: Any, marker: String) -> Any {
    if let text = value as? String { return paths(in: text, marker: marker) }
    if let object = value as? [String: Any] {
      return Dictionary(
        uniqueKeysWithValues: object.map { ($0.key, rewritten($0.value, marker: marker)) })
    }
    if let array = value as? [Any] { return array.map { rewritten($0, marker: marker) } }
    return value
  }

  /// Characters a path in prose can follow.
  private static let openers: Set<Character> = ["\"", "'", "`", "(", "[", "{", "<", "=", ",", ":"]
  /// Characters that end a path in prose.
  private static let closers: Set<Character> = ["\"", "'", "`", ")", "]", "}", ">", ",", ";"]

  /// `text` with each absolute or home path that starts it or follows a space or an opener
  /// rewritten: relative to the run when it runs through `marker`, else to its last component.
  static func paths(in text: String, marker: String) -> String {
    var out = ""
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      let atBoundary =
        index == text.startIndex || text[text.index(before: index)].isWhitespace
        || openers.contains(text[text.index(before: index)])
      let next = text[index...].dropFirst().first
      let startsPath =
        (character == "/" && next != nil && next != "/") || (character == "~" && next == "/")
      guard atBoundary, startsPath else {
        out.append(character)
        index = text.index(after: index)
        continue
      }
      var end = index
      while end < text.endIndex, !text[end].isWhitespace, !closers.contains(text[end]) {
        end = text.index(after: end)
      }
      out += relative(String(text[index..<end]), marker: marker)
      index = end
    }
    return out
  }

  private static func relative(_ path: String, marker: String) -> String {
    if let range = path.range(of: marker) { return String(path[range.upperBound...]) }
    let components = path.split(separator: "/").filter { $0 != "~" }
    return components.last.map(String.init) ?? ""
  }
}
