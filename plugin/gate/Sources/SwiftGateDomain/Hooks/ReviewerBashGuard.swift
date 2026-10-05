/// PreToolUse guard on the review agents' Bash: they hold the tool only to open and close their
/// own run-viewer span, so any other command is denied.
///
/// It is an allowlist read with its own strict lexer rather than ``ShellSyntax``, which splits
/// generously to find commands to deny: here anything the lexer doesn't fully understand denies.
/// A word may hold only plain characters, single-quoted text and the `SG` variable, so no
/// operator, redirection, substitution, glob or second command can reach the shell.
public enum ReviewerBashGuard {
  public static let ruleID = "guard.reviewer-bash"
  /// The agents whose Bash may run only `swiftgate events span start|end`.
  public static let reviewerAgentTypes: Set<String> = [
    "swift-harness:architecture", "swift-harness:test-quality", "swift-harness:verifier",
  ]

  /// The value options each span subcommand takes, as `events span <sub> --help` lists them.
  static let startOptions: Set<String> = [
    "--phase", "--build-run", "--task", "--role", "--parent", "--end-parent",
  ]
  static let endOptions: Set<String> = ["--outcome"]

  /// The violation when a reviewer's command is anything but one span command, else `nil`.
  public static func evaluate(_ command: String, agentType: String?) -> GuardViolation? {
    guard let agentType, reviewerAgentTypes.contains(agentType) else { return nil }
    guard let problem = problem(in: command) else { return nil }
    return GuardViolation(
      ruleID: ruleID,
      reason:
        "`\(agentType)` runs Bash only for its own run-viewer span: exactly 1 "
        + "`swiftgate events span start|end …` command, through the plugin's `bin/swiftgate` "
        + "or `\"$SG\"`, with no `;`, `&&`, `|`, redirection, substitution or second "
        + "command. This command \(problem). Read the code with Read, Grep and Glob; a reviewer "
        + "never changes the tree.")
  }

  /// Why the command isn't 1 span command, or `nil` when it is.
  static func problem(in command: String) -> String? {
    let words: [Word]
    switch lex(command) {
    case .failure(let problem): return problem
    case .success(let lexed): words = lexed
    }
    guard let program = words.first else { return "is empty" }
    if program.literal == "swiftgate" {
      return "runs `swiftgate` from PATH, which may be another install than the plugin under test"
    }
    guard isSwiftgate(program) else { return "doesn't run swiftgate" }
    let rest = words.dropFirst()
    guard rest.allSatisfy({ !$0.usesVariable }) else {
      return "expands a variable outside the program name"
    }
    let arguments = rest.map(\.literal)
    guard arguments.count >= 3, arguments[0] == "events", arguments[1] == "span" else {
      return "isn't `swiftgate events span start|end`"
    }
    switch arguments[2] {
    case "start":
      return optionsProblem(arguments.dropFirst(3), allowed: startOptions, positionals: 0)
    case "end":
      return optionsProblem(arguments.dropFirst(3), allowed: endOptions, positionals: 1)
    default:
      return "isn't `swiftgate events span start|end`"
    }
  }

  /// The program: `$SG` in any quoting, or an absolute `…/bin/swiftgate` path with no `.` or `..`
  /// component. Bare `swiftgate` resolves through PATH, which may hold an older installed plugin
  /// whose span store isn't the one the build reads.
  private static func isSwiftgate(_ word: Word) -> Bool {
    if word.pieces == [.sg] { return true }
    guard !word.usesVariable else { return false }
    let path = word.literal
    guard path.hasPrefix("/"), path.hasSuffix("/bin/swiftgate") else { return false }
    return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
  }

  private static func optionsProblem(
    _ arguments: ArraySlice<String>, allowed: Set<String>, positionals expected: Int
  ) -> String? {
    var seen: Set<String> = []
    var positionals = 0
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      index += 1
      guard argument.hasPrefix("-") else {
        positionals += 1
        continue
      }
      let name = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
      guard allowed.contains(name) else { return "passes `\(name)`, which the span command lacks" }
      guard seen.insert(name).inserted else { return "repeats `\(name)`" }
      if !argument.contains("=") {
        guard index < arguments.endIndex, !arguments[index].hasPrefix("-") else {
          return "gives `\(name)` no value"
        }
        index += 1
      }
    }
    guard positionals == expected else {
      return "passes \(positionals) positional argument(s) where the span command takes \(expected)"
    }
    return nil
  }

  enum Piece: Equatable {
    case text(String)
    /// `$SG` or `${SG}`.
    case sg
  }

  struct Word: Equatable {
    var pieces: [Piece] = []

    var usesVariable: Bool { pieces.contains(.sg) }
    var literal: String {
      pieces.map {
        switch $0 {
        case .text(let text): text
        case .sg: "$SG"
        }
      }.joined()
    }

    mutating func append(_ character: Character) {
      if case .text(let text) = pieces.last {
        pieces[pieces.count - 1] = .text(text + String(character))
      } else {
        pieces.append(.text(String(character)))
      }
    }
  }

  enum Lexed {
    case success([Word])
    case failure(String)
  }

  /// Characters that are literal anywhere in a bash word and start no expansion.
  private static func isPlain(_ character: Character) -> Bool {
    guard character.isASCII else { return false }
    return character.isLetter || character.isNumber || "_./:=@%+,-".contains(character)
  }

  /// Words separated by spaces or tabs; anything else outside a plain character, single quotes,
  /// double quotes around plain text, or `$SG`/`${SG}` fails the whole line.
  static func lex(_ command: String) -> Lexed {
    let characters = Array(command)
    var words: [Word] = []
    var current: Word?
    var index = 0

    func variable(at start: Int) -> Int? {
      for spelling in ["$SG", "${SG}"] {
        let end = start + spelling.count
        guard end <= characters.count, String(characters[start..<end]) == spelling else {
          continue
        }
        if spelling == "$SG", end < characters.count,
          characters[end].isLetter || characters[end].isNumber || characters[end] == "_"
        {
          return nil
        }
        return end
      }
      return nil
    }

    while index < characters.count {
      let character = characters[index]
      switch character {
      case " ", "\t":
        if let word = current { words.append(word) }
        current = nil
        index += 1
      case "'":
        guard let close = characters[(index + 1)...].firstIndex(of: "'") else {
          return .failure("has an unterminated quote")
        }
        var word = current ?? Word()
        if close == index + 1 { word.pieces.append(.text("")) }
        for quoted in characters[(index + 1)..<close] { word.append(quoted) }
        current = word
        index = close + 1
      case "\"":
        var word = current ?? Word()
        var position = index + 1
        var closed = false
        if characters.indices.contains(position), characters[position] == "\"" {
          word.pieces.append(.text(""))
        }
        while position < characters.count {
          let inner = characters[position]
          if inner == "\"" {
            closed = true
            break
          }
          if inner == "$", let end = variable(at: position) {
            word.pieces.append(.sg)
            position = end
          } else if isPlain(inner) || inner == " " {
            word.append(inner)
            position += 1
          } else {
            return .failure("holds `\(inner)` inside double quotes")
          }
        }
        guard closed else { return .failure("has an unterminated quote") }
        current = word
        index = position + 1
      case "$":
        guard let end = variable(at: index) else {
          return .failure("holds a `$` expansion other than `$SG`")
        }
        var word = current ?? Word()
        word.pieces.append(.sg)
        current = word
        index = end
      default:
        guard isPlain(character) else {
          return .failure("holds `\(printable(character))`, which the shell would interpret")
        }
        var word = current ?? Word()
        word.append(character)
        current = word
        index += 1
      }
    }
    if let word = current { words.append(word) }
    return .success(words)
  }

  private static func printable(_ character: Character) -> String {
    switch character {
    case "\n": "\\n"
    case "\r": "\\r"
    default: String(character)
    }
  }
}
