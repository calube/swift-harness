/// Programs that read stdin when given no file to read, and how to tell from their arguments. The
/// Bash tool leaves stdin open whenever the command holds a heredoc, so such a call waits until
/// the tool's timeout.
enum StdinReaders {
  /// How a program's options are spelled: the short letters and long names that take the next
  /// word as their value.
  private struct Options {
    var shortValues: Set<Character> = []
    var longValues: Set<String> = []
  }

  private struct Arguments {
    var operands: [String] = []
    var shortFlags: Set<Character> = []
    var longFlags: Set<String> = []
  }

  private static let pagerOptions = Options(
    shortValues: Set("bhjkoOpPtTxyzD"), longValues: ["pattern", "tag", "log-file"])

  private static let fileReaders: [String: Options] = [
    "cat": Options(),
    "bat": Options(
      shortValues: Set("lHrm"),
      longValues: [
        "language", "highlight-line", "line-range", "map-syntax", "style", "theme", "paging",
        "color", "decorations", "wrap", "tabs", "terminal-width", "file-name", "italic-text",
        "pager", "diff-context", "ignored-suffix",
      ]),
    "head": Options(shortValues: Set("nc"), longValues: ["lines", "bytes"]),
    "tail": Options(shortValues: Set("ncb"), longValues: ["lines", "bytes"]),
    "less": pagerOptions,
    "more": pagerOptions,
  ]

  private static let grepOptions = Options(
    shortValues: Set("efABCmdD"),
    longValues: [
      "regexp", "file", "after-context", "before-context", "context", "max-count", "directories",
      "devices", "include", "exclude", "exclude-dir", "label", "binary-files",
    ])

  /// The programs ``waits(_:_:)`` knows, for the guard's message.
  static let names = ["cat", "bat", "head", "tail", "grep", "less", "more", "read"]

  /// Whether `name` run with `arguments` reads stdin: it names no file, and for `read` sets no
  /// `-t` timeout or `-u` descriptor.
  static func waits(_ name: String, _ arguments: [String]) -> Bool {
    if let options = fileReaders[name] {
      return parse(arguments, options).operands.allSatisfy { $0 == "-" }
    }
    switch name {
    case "grep", "egrep", "fgrep":
      let parsed = parse(arguments, grepOptions)
      let recursive =
        !parsed.shortFlags.isDisjoint(with: "rR")
        || !parsed.longFlags.isDisjoint(with: ["recursive", "dereference-recursive"])
      guard !recursive else { return false }
      let patternGiven =
        !parsed.shortFlags.isDisjoint(with: "ef")
        || !parsed.longFlags.isDisjoint(with: ["regexp", "file"])
      if !patternGiven, parsed.operands.isEmpty { return false }
      let files = patternGiven ? parsed.operands : Array(parsed.operands.dropFirst())
      return files.allSatisfy { $0 == "-" }
    case "read":
      let parsed = parse(arguments, Options(shortValues: Set("tupadnN")))
      return parsed.shortFlags.isDisjoint(with: "tu")
    default:
      return false
    }
  }

  private static func parse(_ arguments: [String], _ options: Options) -> Arguments {
    var parsed = Arguments()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if argument == "--" {
        parsed.operands += arguments[index...]
        break
      }
      if argument == "-" || !argument.hasPrefix("-") {
        parsed.operands.append(argument)
      } else if argument.hasPrefix("--") {
        let body = argument.dropFirst(2)
        let name = String(body.prefix { $0 != "=" })
        parsed.longFlags.insert(name)
        if !body.contains("="), options.longValues.contains(name) { index += 1 }
      } else {
        let letters = argument.dropFirst()
        for (offset, letter) in letters.enumerated() {
          parsed.shortFlags.insert(letter)
          guard options.shortValues.contains(letter) else { continue }
          if offset == letters.count - 1 { index += 1 }
          break
        }
      }
    }
    return parsed
  }
}
