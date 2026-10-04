import Foundation

/// The reports 1 `{junit}` path stands for. Some runners write more than the 1 file the path
/// names, and a failure in a report left unread would let the baseline absorb it.
public enum JUnitReports {
  /// Reports a runner writes beside `junitPath` when given it as a file: `swift test
  /// --xunit-output <name>.xml` writes XCTest's cases there and Swift Testing's to
  /// `<name>-swift-testing.xml`.
  public static func companionPaths(of junitPath: String) -> [String] {
    let stem = junitPath.hasSuffix(".xml") ? String(junitPath.dropLast(4)) : junitPath
    return ["\(stem)-swift-testing.xml"]
  }

  /// 1 document holding every case of `documents`, in order; `nil` when there are none. A lone
  /// document comes back as it was written, so a malformed one still reads as malformed.
  public static func combined(_ documents: [Data]) -> Data? {
    guard documents.count > 1 else { return documents.first }
    var text = "<testsuites>\n"
    for document in documents {
      var body = String(decoding: document, as: UTF8.self)
      if let declaration = body.range(of: "<?xml"), let end = body.range(of: "?>"),
        body[..<declaration.lowerBound].allSatisfy(\.isWhitespace)
      {
        body.removeSubrange(body.startIndex..<end.upperBound)
      }
      text += body + "\n"
    }
    return Data((text + "</testsuites>\n").utf8)
  }

  /// Text safe inside an XML attribute or element. Control characters other than tab and newline
  /// are not XML at all, so a test that prints one keeps the rest of its output.
  static func escaped(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "\t", "\n": result.unicodeScalars.append(scalar)
      case _ where scalar.value < 0x20: continue
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}
