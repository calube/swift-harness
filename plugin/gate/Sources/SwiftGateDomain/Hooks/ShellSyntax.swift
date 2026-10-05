/// A best-effort split of a shell command line into simple commands, for the Bash guards. It errs
/// toward finding more commands than bash would run: command substitutions, backticks and
/// `sh -c` scripts are split out and checked as commands of their own. It is a tripwire for
/// accidents, not a sandbox; the permission system is the hard boundary.
public struct SimpleCommand: Sendable, Equatable {
  /// Leading `NAME=value` words, including those given to `env`.
  public let assignments: [String]
  /// The executable's basename after wrappers (`sudo`, `env`, `xcrun`, `time`, …) are stripped.
  public let name: String?
  public let arguments: [String]
  /// The targets of this command's output redirections (`>`, `>>`, `>|`, `&>`, `<>`, `>&file`),
  /// as spelled. They are not ``arguments``.
  public let redirectTargets: [String]
}

/// An operator between two commands of a line, as written before the later one.
enum ShellLink: Equatable {
  case and, or, pipe, background, open, close
  /// `;` or a newline.
  case sequence
}

/// A simple command and whether it came from a heredoc's text rather than the command line.
struct ParsedCommand {
  let command: SimpleCommand
  /// Heredoc text is read as commands only when a shell on its line may run it, or, in an
  /// unquoted heredoc, inside the `$( … )` and backticks the shell expands. It is checked by the
  /// Bash guard but never names a write.
  let isHeredocBody: Bool
  /// The words as written, before wrappers and assignments are stripped.
  let words: [String]
  /// The operators between the previous command of the same script and this one; empty for the
  /// script's first.
  let links: [ShellLink]
  /// Run by the line's own shell: not a substitution, heredoc text or a `sh -c`/`eval` script.
  let isTopLevel: Bool
  /// Whether a redirection feeds its stdin: `<`, a heredoc, a here-string, `<&` or `<(…)`.
  let hasInputRedirect: Bool
}

public enum ShellSyntax {
  public static func simpleCommands(in line: String) -> [SimpleCommand] {
    parse(line).map(\.command)
  }

  static func parse(_ line: String) -> [ParsedCommand] {
    words(in: Array(line), depth: 0, isHeredocBody: false).flatMap { expand($0, depth: 0) }
  }

  /// Nesting beyond this is not worth following; the outer command is still checked.
  private static let maxDepth = 4

  private static func expand(_ parsed: Tokenized, depth: Int) -> [ParsedCommand] {
    let command = normalize(parsed.words, redirectTargets: parsed.redirectTargets)
    var result = [
      ParsedCommand(
        command: command, isHeredocBody: parsed.isHeredocBody, words: parsed.words,
        links: parsed.links, isTopLevel: depth == 0 && parsed.depth == 0 && !parsed.isHeredocBody,
        hasInputRedirect: parsed.hasInputRedirect)
    ]
    guard depth < maxDepth, let name = command.name else { return result }
    var script: String?
    if ["sh", "bash", "zsh", "dash"].contains(name),
      let flag = command.arguments.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
      flag + 1 < command.arguments.count
    {
      script = command.arguments[flag + 1]
    } else if name == "eval" {
      script = command.arguments.joined(separator: " ")
    }
    if let script {
      result += Self.words(in: Array(script), depth: depth + 1, isHeredocBody: parsed.isHeredocBody)
        .flatMap { expand($0, depth: depth + 1) }
    }
    return result
  }

  /// Commands that run text they are fed as shell commands. A heredoc on a line with none of
  /// them is data, such as a file `cat` writes or a script `python3` runs.
  static let interpreters: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "fish", "eval", "source", ".", "xargs", "ssh",
  ]

  private static let wrappers: Set<String> = [
    "sudo", "command", "exec", "time", "nohup", "nice", "caffeinate", "xcrun", "env",
  ]
  /// Wrapper options that consume the following word.
  private static let optionsWithValues: Set<String> = [
    "-sdk", "--sdk", "-toolchain", "--toolchain", "-u", "-g", "-n", "-S", "-C",
  ]

  static func normalize(_ words: [String], redirectTargets: [String] = []) -> SimpleCommand {
    var rest = words[...]
    var assignments: [String] = []
    while true {
      while let first = rest.first, isAssignment(first) {
        assignments.append(first)
        rest = rest.dropFirst()
      }
      guard let first = rest.first, wrappers.contains(basename(first)) else { break }
      rest = rest.dropFirst()
      while let option = rest.first, option.hasPrefix("-") {
        rest = rest.dropFirst()
        if optionsWithValues.contains(option) { rest = rest.dropFirst() }
      }
    }
    return SimpleCommand(
      assignments: assignments, name: rest.first.map(basename), arguments: Array(rest.dropFirst()),
      redirectTargets: redirectTargets)
  }

  static func isAssignment(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let head = name.first, head == "_" || head.isLetter else { return false }
    return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  static func basename(_ word: String) -> String {
    word.split(separator: "/").last.map(String.init) ?? word
  }

  // MARK: - Tokenizing

  private struct Tokenized {
    var words: [String]
    var redirectTargets: [String]
    var isHeredocBody: Bool
    var links: [ShellLink]
    var depth: Int
    var hasInputRedirect: Bool
  }

  private static func words(in characters: [Character], depth: Int, isHeredocBody: Bool)
    -> [Tokenized]
  {
    var tokenizer = Tokenizer(characters: characters, depth: depth, isHeredocBody: isHeredocBody)
    tokenizer.run()
    return tokenizer.commands
  }

  private struct Tokenizer {
    /// What the word after a redirection operator is.
    private enum Operand {
      case writeTarget
      /// After `>&`: a descriptor (`2`, `-`) duplicates it, any other word is a file written.
      case writeTargetUnlessDescriptor
      /// A file read, a descriptor, or a here-string: never a write.
      case ignored
      case heredocDelimiter(stripsTabs: Bool)
    }

    let characters: [Character]
    let depth: Int
    let isHeredocBody: Bool
    var commands: [Tokenized] = []
    private var words: [String] = []
    private var redirectTargets: [String] = []
    private var word = ""
    private var inWord = false
    private var index = 0
    private var operand: Operand?
    private var heredocs: [(delimiter: String, stripsTabs: Bool, quoted: Bool)] = []
    private var links: [ShellLink] = []
    private var hasInputRedirect = false
    /// Whether the word being read had a quote or backslash, which makes a heredoc literal.
    private var wordQuoted = false
    /// The index in ``commands`` of the current line's first command.
    private var lineStart = 0

    init(characters: [Character], depth: Int, isHeredocBody: Bool) {
      self.characters = characters
      self.depth = depth
      self.isHeredocBody = isHeredocBody
    }

    mutating func run() {
      while index < characters.count {
        let character = characters[index]
        switch character {
        case "'":
          inWord = true
          wordQuoted = true
          index += 1
          while index < characters.count, characters[index] != "'" {
            word.append(characters[index])
            index += 1
          }
          index += 1
        case "\"":
          inWord = true
          wordQuoted = true
          index += 1
          doubleQuoted()
        case "\\":
          wordQuoted = true
          if index + 1 < characters.count, characters[index + 1] != "\n" {
            word.append(characters[index + 1])
            inWord = true
          }
          index += 2
        case "$" where peek(1) == "(" && peek(2) != "(":
          substitution(openingAt: index + 1)
        case "`":
          backticks()
        case " ", "\t":
          endWord()
          index += 1
        case "&" where peek(1) == ">":
          endWord()
          index += peek(2) == ">" ? 3 : 2
          operand = .writeTarget
        case "\n":
          endCommand()
          links.append(.sequence)
          index += 1
          if !heredocs.isEmpty { heredocBodies() }
          lineStart = commands.count
        case ";", "&", "|", "(", ")":
          endCommand()
          links.append(link(at: character))
        case "<", ">":
          redirection()
        case "#" where !inWord:
          while index < characters.count, characters[index] != "\n" { index += 1 }
        default:
          word.append(character)
          inWord = true
          index += 1
        }
      }
      endCommand()
    }

    /// The operator starting at `index`, which it moves past.
    private mutating func link(at character: Character) -> ShellLink {
      let next = peek(1)
      index += 1
      switch character {
      case "&" where next == "&":
        index += 1
        return .and
      case "|" where next == "|":
        index += 1
        return .or
      case "|" where next == "&":
        index += 1
        return .pipe
      case "&": return .background
      case "|": return .pipe
      case "(": return .open
      case ")": return .close
      default: return .sequence
      }
    }

    private func peek(_ offset: Int) -> Character? {
      index + offset < characters.count ? characters[index + offset] : nil
    }

    private mutating func doubleQuoted() {
      while index < characters.count, characters[index] != "\"" {
        let character = characters[index]
        if character == "\\", index + 1 < characters.count {
          word.append(characters[index + 1])
          index += 2
        } else if character == "$", peek(1) == "(", peek(2) != "(" {
          substitution(openingAt: index + 1)
        } else if character == "`" {
          backticks()
        } else {
          word.append(character)
          index += 1
        }
      }
      index += 1
    }

    /// A redirection operator at `index`. Digits written directly before it name a descriptor,
    /// not an argument.
    private mutating func redirection() {
      if inWord, !word.isEmpty, word.allSatisfy(\.isASCII), word.allSatisfy(\.isNumber) {
        word = ""
        inWord = false
      }
      endWord()
      let first = characters[index]
      index += 1
      if first == ">" {
        switch peek(0) {
        case ">", "|":
          index += 1
          operand = .writeTarget
        case "&":
          index += 1
          operand = .writeTargetUnlessDescriptor
        default:
          operand = .writeTarget
        }
        return
      }
      hasInputRedirect = true
      switch peek(0) {
      case "<" where peek(1) == "<":
        index += 2
        operand = .ignored
      case "<":
        index += 1
        let stripsTabs = peek(0) == "-"
        if stripsTabs { index += 1 }
        operand = .heredocDelimiter(stripsTabs: stripsTabs)
      case ">":
        index += 1
        operand = .writeTarget
      case "&":
        index += 1
        operand = .ignored
      default:
        operand = .ignored
      }
    }

    /// The bodies of the heredocs opened on the line just ended, each up to its delimiter line.
    private mutating func heredocBodies() {
      let pending = heredocs
      heredocs = []
      let interpreted = commands[lineStart...].contains { command in
        ShellSyntax.normalize(command.words).name.map(ShellSyntax.interpreters.contains) ?? false
      }
      for heredoc in pending {
        var body: [Character] = []
        while index < characters.count {
          var end = index
          while end < characters.count, characters[end] != "\n" { end += 1 }
          let line = characters[index..<end]
          index = min(end + 1, characters.count)
          let compared = heredoc.stripsTabs ? line.drop(while: { $0 == "\t" }) : line
          if String(compared) == heredoc.delimiter { break }
          body += line
          body.append("\n")
        }
        guard depth < ShellSyntax.maxDepth else { continue }
        if interpreted {
          commands += ShellSyntax.words(in: body, depth: depth + 1, isHeredocBody: true)
        } else if !heredoc.quoted {
          for script in Self.substitutions(in: body) {
            commands += ShellSyntax.words(in: script, depth: depth + 1, isHeredocBody: true)
          }
        }
      }
    }

    /// The scripts inside each `$( … )` and backticks of unquoted heredoc text, which the shell
    /// runs while it writes the text.
    private static func substitutions(in body: [Character]) -> [[Character]] {
      var scripts: [[Character]] = []
      var cursor = 0
      while cursor < body.count {
        let character = body[cursor]
        let next = cursor + 1 < body.count ? body[cursor + 1] : nil
        if character == "\\" {
          cursor += 2
        } else if character == "$", next == "(",
          cursor + 2 >= body.count || body[cursor + 2] != "("
        {
          var depth = 1
          var end = cursor + 2
          var quote: Character?
          while end < body.count {
            let inner = body[end]
            if let active = quote {
              if inner == active { quote = nil }
            } else if inner == "'" || inner == "\"" {
              quote = inner
            } else if inner == "(" {
              depth += 1
            } else if inner == ")" {
              depth -= 1
              if depth == 0 { break }
            }
            end += 1
          }
          scripts.append(Array(body[(cursor + 2)..<min(end, body.count)]))
          cursor = end + 1
        } else if character == "`" {
          var end = cursor + 1
          while end < body.count, body[end] != "`" { end += 1 }
          scripts.append(Array(body[(cursor + 1)..<min(end, body.count)]))
          cursor = end + 1
        } else {
          cursor += 1
        }
      }
      return scripts
    }

    /// `$( … )`: the inner script is checked as commands of its own; the word it sits in keeps a
    /// placeholder, since its value is unknown.
    private mutating func substitution(openingAt open: Int) {
      var depthCount = 1
      var cursor = open + 1
      var quote: Character?
      while cursor < characters.count {
        let character = characters[cursor]
        if let active = quote {
          if character == active { quote = nil }
        } else if character == "'" || character == "\"" {
          quote = character
        } else if character == "(" {
          depthCount += 1
        } else if character == ")" {
          depthCount -= 1
          if depthCount == 0 { break }
        }
        cursor += 1
      }
      nested(Array(characters[(open + 1)..<min(cursor, characters.count)]))
      word += "$(…)"
      inWord = true
      index = cursor + 1
    }

    private mutating func backticks() {
      var cursor = index + 1
      while cursor < characters.count, characters[cursor] != "`" { cursor += 1 }
      nested(Array(characters[(index + 1)..<min(cursor, characters.count)]))
      word += "`…`"
      inWord = true
      index = cursor + 1
    }

    private mutating func nested(_ script: [Character]) {
      guard depth < ShellSyntax.maxDepth else { return }
      commands += ShellSyntax.words(in: script, depth: depth + 1, isHeredocBody: isHeredocBody)
    }

    private mutating func endWord() {
      if inWord {
        switch operand {
        case .writeTarget?:
          redirectTargets.append(word)
        case .writeTargetUnlessDescriptor?:
          let isDescriptor = word == "-" || (!word.isEmpty && word.allSatisfy(\.isNumber))
          if !isDescriptor { redirectTargets.append(word) }
        case .ignored?:
          break
        case .heredocDelimiter(let stripsTabs)?:
          heredocs.append((word, stripsTabs, wordQuoted))
        case nil:
          words.append(word)
        }
        operand = nil
      }
      word = ""
      inWord = false
      wordQuoted = false
    }

    private mutating func endCommand() {
      endWord()
      operand = nil
      if !words.isEmpty || !redirectTargets.isEmpty {
        commands.append(
          Tokenized(
            words: words, redirectTargets: redirectTargets, isHeredocBody: isHeredocBody,
            links: links, depth: depth, hasInputRedirect: hasInputRedirect))
        links = []
      }
      words = []
      redirectTargets = []
      hasInputRedirect = false
    }
  }
}
