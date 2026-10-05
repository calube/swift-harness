/// A path a shell command writes, as spelled.
public struct ShellWriteTarget: Sendable, Equatable {
  public let path: String
  /// The basenames `cp`, `mv`, `install` or `ln` place inside ``path`` when it is a directory.
  /// Empty for every other write.
  public let entries: [String]
  /// `path` is a directory for certain: given by `-t`, or spelled with a trailing `/`.
  public let isDirectory: Bool

  public init(path: String, entries: [String] = [], isDirectory: Bool = false) {
    self.path = path
    self.entries = entries
    self.isDirectory = isDirectory
  }
}

extension ShellSyntax {
  /// Every path a command line may write: output redirections, `tee`, the
  /// destinations of `cp`/`mv`/`install`/`ln` (and what `mv` moves away), the operands of
  /// `rm`/`rmdir`/`unlink`/`truncate`/`touch`, `dd of=`, the files of `sed -i`/`perl -i`, and the
  /// pathspecs of `git checkout`/`restore`/`rm`/`mv`.
  /// A relative path is named under the directory a literal absolute `cd` or `pushd` certainly
  /// moved the shell to (see ``knownDirectories(_:directoryExists:)``). Otherwise it is relative
  /// to the shell's starting directory and also named under every literal `cd` of the line, so a
  /// `cd` the shell may not have made never hides a write from the starting directory. A path the
  /// shell would expand (`$VAR`, `$(…)`, backticks), code an interpreter runs, and heredoc text
  /// name nothing: a static reading can't know them.
  /// - Parameter directoryExists: whether an absolute path is a directory now.
  public static func writeTargets(
    in line: String, directoryExists: (String) -> Bool
  ) -> [ShellWriteTarget] {
    let parsed = parse(line)
    let directories = parsed.filter { !$0.isHeredocBody }.map(\.command)
      .compactMap(changedDirectory)
    let possible = possibleDirectories(parsed, directoryExists: directoryExists)
    var targets: [ShellWriteTarget] = []
    for (index, entry) in parsed.enumerated() where !entry.isHeredocBody {
      let command = entry.command
      let written =
        command.redirectTargets.map { ShellWriteTarget(path: $0) } + writtenOperands(of: command)
      for target in written where isLiteral(target.path) {
        let path = target.path
        let spellings: [String]
        if path.hasPrefix("/") || path.hasPrefix("~") {
          spellings = [path]
        } else if let directories = possible[index] {
          spellings = directories.map { directory in
            switch directory {
            case .start: path
            case .path(let base): base + "/" + path
            }
          }
        } else {
          spellings = [path] + directories.map { $0 + "/" + path }
        }
        for spelling in spellings {
          let respelled = ShellWriteTarget(
            path: spelling, entries: target.entries, isDirectory: target.isDirectory)
          if !targets.contains(respelled) { targets.append(respelled) }
        }
      }
    }
    return targets
  }

  // MARK: - The working directory a cd leaves

  /// A directory a command may run in.
  enum ShellDirectory: Hashable {
    /// The shell's starting directory.
    case start
    /// A path as a `cd` spelled it: absolute, or relative to the starting directory.
    case path(String)
  }

  /// Every directory each top-level command may run in, by index into `commands`. A command
  /// missing from the map may run anywhere a static reading can't follow.
  static func possibleDirectories(
    _ commands: [ParsedCommand], directoryExists: (String) -> Bool
  ) -> [Int: [ShellDirectory]] {
    knownDirectories(commands, directoryExists: directoryExists).mapValues { [.path($0)] }
  }

  /// Commands that can move the shell, or define something that does, out of a static reading's
  /// sight. A line holding one at top level is read as if no `cd` were certain.
  private static let opaqueCommands: Set<String> = [
    "eval", "source", ".", "trap", "alias", "function", "builtin", "enable",
  ]
  private static let directoryCommands: Set<String> = ["cd", "pushd", "popd"]
  /// Words that open or continue a compound command; the command proper follows them.
  private static let reservedWords: Set<String> = [
    "if", "then", "else", "elif", "while", "until", "do", "{",
  ]

  /// The directory each top-level command certainly runs in, by index into `commands`, when a
  /// literal absolute `cd`/`pushd` put it there. A command is in that directory when either:
  /// - it follows the `cd` through `&&` (and pipes after the first `&&`), with no other directory
  ///   command between, so it runs only if the `cd` succeeded; or
  /// - the `cd` is the line's first command, its directory exists now, and the commands up to this
  ///   one follow by `;`, newline or `&&` with no other directory command between, so the `cd`
  ///   ran and succeeded before it.
  /// Anything else, a `cd` to a variable, a glob or `~`, in a pipeline, subshell or behind `||`
  /// or `!`, or through a wrapper like `env`, leaves the command's directory unknown. So does a
  /// line that defines a function or runs `eval`, `source` or `trap` at top level.
  static func knownDirectories(
    _ commands: [ParsedCommand], directoryExists: (String) -> Bool
  ) -> [Int: String] {
    let top = commands.indices.filter { commands[$0].isTopLevel }
    let opaque = top.contains { index in
      let entry = commands[index]
      let name = unwrapped(entry).name
      return name.map(opaqueCommands.contains) == true
        || zip(entry.links, entry.links.dropFirst()).contains { $0 == (.open, .close) }
    }
    guard !opaque else { return [:] }

    var leading: String?
    if let first = top.first, first == commands.startIndex, commands[first].links.isEmpty,
      top.count > 1, Set(commands[top[1]].links).isSubset(of: [.sequence, .and]),
      let directory = certainDirectory(commands[first]), directoryExists(directory)
    {
      leading = directory
    }

    var known: [Int: String] = [:]
    for position in top.indices.dropFirst() {
      if let directory = andChainDirectory(top, position, commands) {
        known[top[position]] = directory
        continue
      }
      guard let leading else { continue }
      let between = top[1..<position].map { commands[$0] }
      if between.allSatisfy({ !isDirectoryCommand($0) }) { known[top[position]] = leading }
    }
    return known
  }

  /// The directory of the `cd` that `top[position]` follows through `&&` and pipes only.
  private static func andChainDirectory(
    _ top: [Int], _ position: Int, _ commands: [ParsedCommand]
  ) -> String? {
    var current = position
    while current > 0 {
      let links = commands[top[current]].links
      guard links == [.and] || links == [.pipe] else { return nil }
      let previous = commands[top[current - 1]]
      if isDirectoryCommand(previous) {
        guard links == [.and], !previous.links.contains(.or), !previous.links.contains(.pipe)
        else { return nil }
        return certainDirectory(previous)
      }
      current -= 1
    }
    return nil
  }

  /// The words after any reserved words and `!`, re-read as a simple command.
  private static func unwrapped(_ entry: ParsedCommand) -> SimpleCommand {
    normalize(Array(entry.words.drop { reservedWords.contains($0) || $0 == "!" }))
  }

  private static func isDirectoryCommand(_ entry: ParsedCommand) -> Bool {
    unwrapped(entry).name.map(directoryCommands.contains) == true
  }

  /// The directory a plain `cd` or `pushd` to 1 literal absolute path moves the shell to; `nil`
  /// for any other command, and for a `cd` behind `!`, a wrapper or an assignment.
  private static func certainDirectory(_ entry: ParsedCommand) -> String? {
    let words = Array(entry.words.drop { reservedWords.contains($0) })
    guard let name = words.first else { return nil }
    let options: Set<String>
    switch name {
    case "cd": options = ["-L", "-P", "--"]
    case "pushd": options = ["--"]
    default: return nil
    }
    let operands = words.dropFirst().drop { options.contains($0) }
    guard operands.count == 1, let directory = operands.first, directory.hasPrefix("/"),
      isLiteral(directory), !directory.contains(where: { "*?[{~\\".contains($0) })
    else { return nil }
    var trimmed = Substring(directory)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
  }

  private static func isLiteral(_ path: String) -> Bool {
    !path.isEmpty && path != "-" && !path.contains("$") && !path.contains("`")
  }

  private static func changedDirectory(_ command: SimpleCommand) -> String? {
    guard command.name == "cd" || command.name == "pushd" else { return nil }
    guard let directory = command.arguments.first(where: { !$0.hasPrefix("-") }),
      isLiteral(directory)
    else { return nil }
    return directory
  }

  private static func writtenOperands(of command: SimpleCommand) -> [ShellWriteTarget] {
    let arguments = command.arguments
    if let name = command.name, ["cp", "mv", "ln", "install", "ginstall"].contains(name) {
      return copyDestinations(name, arguments)
    }
    if command.name == "git" { return gitPathspecs(arguments) }
    return writtenFiles(command.name, arguments).map { ShellWriteTarget(path: $0) }
  }

  /// The options each git subcommand that rewrites working-tree files takes with a value.
  private static let gitPathspecValued: [String: Set<String>] = [
    "checkout": ["-b", "-B", "--orphan", "--conflict", "--pathspec-from-file"],
    "restore": ["-s", "--source", "--conflict", "--pathspec-from-file"],
    "rm": ["--pathspec-from-file"],
  ]

  /// What `git checkout`, `restore`, `rm` and `mv` may rewrite or delete: every operand, the
  /// tree-ish or branch included, since only the repository can tell a branch from a path, and a
  /// branch name resolves to a path nothing guards. A branch switch rewrites the whole tree and
  /// names no file, so it is judged like a recursive delete of a guarded file's parent.
  private static func gitPathspecs(_ arguments: [String]) -> [ShellWriteTarget] {
    let git = gitInvocation(arguments)
    let targets: [ShellWriteTarget]
    switch git.subcommand {
    case "mv"?:
      targets = copyDestinations("mv", Array(git.arguments))
    case let name? where gitPathspecValued[name] != nil:
      targets = scan(Array(git.arguments), valued: gitPathspecValued[name] ?? []).operands.map {
        ShellWriteTarget(path: $0)
      }
    default:
      return []
    }
    guard let directory = git.directory else { return targets }
    return targets.map { target in
      guard !target.path.hasPrefix("/"), !target.path.hasPrefix("~") else { return target }
      return ShellWriteTarget(
        path: directory + "/" + target.path, entries: target.entries,
        isDirectory: target.isDirectory)
    }
  }

  private static let gitOptionsWithValues: Set<String> = [
    "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env",
  ]

  /// A git command line split at its subcommand. `directory` is where `-C` moves git before it
  /// runs, `nil` without one; a relative pathspec resolves under it.
  static func gitInvocation(_ arguments: [String]) -> (
    subcommand: String?, arguments: ArraySlice<String>, directory: String?
  ) {
    var rest = arguments[...]
    var directory: String?
    while let option = rest.first, option.hasPrefix("-") {
      rest = rest.dropFirst()
      guard gitOptionsWithValues.contains(option), let value = rest.first else { continue }
      rest = rest.dropFirst()
      if option == "-C" {
        directory =
          value.hasPrefix("/") || directory == nil ? value : directory.map { $0 + "/" + value }
      }
    }
    return (rest.first, rest.dropFirst(), directory)
  }

  private static func writtenFiles(_ name: String?, _ arguments: [String]) -> [String] {
    switch name {
    case "tee"?:
      return scan(arguments, valued: []).operands
    case "rm"?, "rmdir"?, "unlink"?, "srm"?, "trash"?:
      return scan(arguments, valued: []).operands
    case "shred"?:
      return scan(arguments, valued: ["-n", "-s", "--iterations", "--size"]).operands
    case "truncate"?:
      return scan(arguments, valued: ["-s", "-r", "--size", "--reference"]).operands
    case "touch"?:
      return scan(arguments, valued: ["-t", "-d", "-r", "-A", "--date", "--reference"]).operands
    case "dd"?:
      return arguments.filter { $0.hasPrefix("of=") }.map { String($0.dropFirst(3)) }
    case "sed"?, "gsed"?:
      return sedFiles(arguments)
    case "perl"?:
      return perlFiles(arguments)
    default:
      return []
    }
  }

  private static let targetDirectoryOptions: Set<String> = ["-t", "--target-directory"]

  /// Where `cp`, `mv`, `ln` and `install` write: the destination, with each source's name as an
  /// entry in case it is a directory. `mv` also removes its sources.
  private static func copyDestinations(_ name: String, _ arguments: [String])
    -> [ShellWriteTarget]
  {
    var valued: Set<String> = targetDirectoryOptions.union(["-S", "--suffix"])
    if name.hasSuffix("install") {
      valued.formUnion(["-m", "-o", "-g", "-B", "-f", "--mode", "--owner", "--group"])
    }
    let scanned = scan(arguments, valued: valued)
    var operands = scanned.operands
    if name.hasSuffix("install"),
      arguments.contains(where: { $0 == "-d" || $0 == "--directory" })
    {
      return operands.map { ShellWriteTarget(path: $0) }
    }
    var destination: Substring
    var isDirectory: Bool
    if let directory = scanned.values.last(where: { targetDirectoryOptions.contains($0.option) }) {
      destination = Substring(directory.value)
      isDirectory = true
    } else if operands.count >= 2 {
      destination = Substring(operands.removeLast())
      isDirectory = false
    } else if name == "ln", let only = operands.first {
      return [ShellWriteTarget(path: basename(only))]
    } else {
      return []
    }
    while destination.count > 1, destination.hasSuffix("/") {
      destination = destination.dropLast()
      isDirectory = true
    }
    let written = ShellWriteTarget(
      path: String(destination), entries: operands.map(basename), isDirectory: isDirectory)
    return [written] + (name == "mv" ? operands.map { ShellWriteTarget(path: $0) } : [])
  }

  /// `sed` writes only in place; its first operand is the script unless `-e`/`-f` gave one.
  private static func sedFiles(_ arguments: [String]) -> [String] {
    var inPlace = false
    var scriptGiven = false
    var operands: [String] = []
    var index = 0
    var optionsEnded = false
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if optionsEnded || argument == "-" || !argument.hasPrefix("-") {
        operands.append(argument)
        continue
      }
      if argument == "--" {
        optionsEnded = true
      } else if argument.hasPrefix("--") {
        if argument == "--in-place" || argument.hasPrefix("--in-place=") { inPlace = true }
        if argument.hasPrefix("--expression") || argument.hasPrefix("--file") {
          scriptGiven = true
        }
        if ["--expression", "--file", "--line-length"].contains(argument) { index += 1 }
      } else {
        let letters = Array(argument.dropFirst())
        for (offset, letter) in letters.enumerated() {
          let attached = offset + 1 < letters.count
          if letter == "i" || letter == "I" {
            inPlace = true
            // A bare -i may take its backup suffix as the next word: BSD's `-i ''`, or `-i .bak`.
            if !attached, index < arguments.count,
              arguments[index].isEmpty || arguments[index].hasPrefix(".")
            {
              index += 1
            }
            break
          }
          if letter == "e" || letter == "f" || letter == "l" {
            if letter != "l" { scriptGiven = true }
            if !attached { index += 1 }
            break
          }
        }
      }
    }
    guard inPlace else { return [] }
    return scriptGiven ? operands : Array(operands.dropFirst())
  }

  /// `perl` writes only in place; its first operand is the script unless `-e`/`-E` gave code.
  /// Options end at the first operand: later words are the script's arguments.
  private static func perlFiles(_ arguments: [String]) -> [String] {
    var inPlace = false
    var codeGiven = false
    var operands: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if !operands.isEmpty || argument == "-" || !argument.hasPrefix("-") {
        operands.append(argument)
        continue
      }
      if argument == "--" {
        operands += arguments[index...]
        break
      }
      let letters = Array(argument.dropFirst())
      for (offset, letter) in letters.enumerated() {
        let attached = offset + 1 < letters.count
        if letter == "i" {
          inPlace = true
          break
        }
        if letter == "e" || letter == "E" {
          codeGiven = true
          if !attached { index += 1 }
          break
        }
        if "MmIxdDC0l".contains(letter) { break }
      }
    }
    guard inPlace else { return [] }
    return codeGiven ? operands : Array(operands.dropFirst())
  }

  /// Operands and option values of a command whose options in `valued` take a value, attached
  /// (`-s0`, `--size=0`) or as the next word. `--` ends options.
  private static func scan(_ arguments: [String], valued: Set<String>)
    -> (operands: [String], values: [(option: String, value: String)])
  {
    var operands: [String] = []
    var values: [(option: String, value: String)] = []
    var index = 0
    var optionsEnded = false
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if optionsEnded || argument == "-" || !argument.hasPrefix("-") {
        operands.append(argument)
      } else if argument == "--" {
        optionsEnded = true
      } else if argument.hasPrefix("--") {
        if let equals = argument.firstIndex(of: "=") {
          values.append(
            (String(argument[..<equals]), String(argument[argument.index(after: equals)...])))
        } else if valued.contains(argument), index < arguments.count {
          values.append((argument, arguments[index]))
          index += 1
        }
      } else {
        let letters = Array(argument.dropFirst())
        for (offset, letter) in letters.enumerated() where valued.contains("-\(letter)") {
          let rest = String(letters[(offset + 1)...])
          if !rest.isEmpty {
            values.append(("-\(letter)", rest))
          } else if index < arguments.count {
            values.append(("-\(letter)", arguments[index]))
            index += 1
          }
          break
        }
      }
    }
    return (operands, values)
  }
}
