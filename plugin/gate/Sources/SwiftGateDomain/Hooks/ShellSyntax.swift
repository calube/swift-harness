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
}

public enum ShellSyntax {
  public static func simpleCommands(in line: String) -> [SimpleCommand] {
    words(in: Array(line), depth: 0).flatMap { expand($0, depth: 0) }
  }

  /// Nesting beyond this is not worth following; the outer command is still checked.
  private static let maxDepth = 4

  private static func expand(_ words: [String], depth: Int) -> [SimpleCommand] {
    let command = normalize(words)
    var result = [command]
    guard depth < maxDepth, let name = command.name else { return result }
    if ["sh", "bash", "zsh", "dash"].contains(name),
      let flag = command.arguments.firstIndex(where: { $0.hasPrefix("-") && $0.contains("c") }),
      flag + 1 < command.arguments.count
    {
      result += Self.words(in: Array(command.arguments[flag + 1]), depth: depth + 1)
        .flatMap { expand($0, depth: depth + 1) }
    } else if name == "eval" {
      result += Self.words(in: Array(command.arguments.joined(separator: " ")), depth: depth + 1)
        .flatMap { expand($0, depth: depth + 1) }
    }
    return result
  }

  private static let wrappers: Set<String> = [
    "sudo", "command", "exec", "time", "nohup", "nice", "caffeinate", "xcrun", "env",
  ]
  /// Wrapper options that consume the following word.
  private static let optionsWithValues: Set<String> = [
    "-sdk", "--sdk", "-toolchain", "--toolchain", "-u", "-g", "-n", "-S", "-C",
  ]

  static func normalize(_ words: [String]) -> SimpleCommand {
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
      assignments: assignments, name: rest.first.map(basename), arguments: Array(rest.dropFirst()))
  }

  static func isAssignment(_ word: String) -> Bool {
    guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
    let name = word[..<equals]
    guard let head = name.first, head == "_" || head.isLetter else { return false }
    return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
  }

  private static func basename(_ word: String) -> String {
    word.split(separator: "/").last.map(String.init) ?? word
  }

  // MARK: - Tokenizing

  private static func words(in characters: [Character], depth: Int) -> [[String]] {
    var tokenizer = Tokenizer(characters: characters, depth: depth)
    tokenizer.run()
    return tokenizer.commands
  }

  private struct Tokenizer {
    let characters: [Character]
    let depth: Int
    var commands: [[String]] = []
    private var words: [String] = []
    private var word = ""
    private var inWord = false
    private var index = 0

    init(characters: [Character], depth: Int) {
      self.characters = characters
      self.depth = depth
    }

    mutating func run() {
      while index < characters.count {
        let character = characters[index]
        switch character {
        case "'":
          inWord = true
          index += 1
          while index < characters.count, characters[index] != "'" {
            word.append(characters[index])
            index += 1
          }
          index += 1
        case "\"":
          inWord = true
          index += 1
          doubleQuoted()
        case "\\":
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
        case ";", "&", "|", "\n", "(", ")":
          endCommand()
          index += 1
        case "<", ">":
          endWord()
          index += 1
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
      commands += ShellSyntax.words(in: script, depth: depth + 1)
    }

    private mutating func endWord() {
      if inWord { words.append(word) }
      word = ""
      inWord = false
    }

    private mutating func endCommand() {
      endWord()
      if !words.isEmpty { commands.append(words) }
      words = []
    }
  }
}
