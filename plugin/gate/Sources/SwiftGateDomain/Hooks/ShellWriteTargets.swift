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
  /// A relative path is relative to the shell's starting directory; after a literal `cd`, it is
  /// also named under that directory. A path the shell would expand (`$VAR`, `$(…)`, backticks),
  /// code an interpreter runs, and heredoc text name nothing: a static reading can't know them.
  public static func writeTargets(in line: String) -> [ShellWriteTarget] {
    let commands = parse(line).filter { !$0.isHeredocBody }.map(\.command)
    let directories = commands.compactMap(changedDirectory)
    var targets: [ShellWriteTarget] = []
    for command in commands {
      let written =
        command.redirectTargets.map { ShellWriteTarget(path: $0) } + writtenOperands(of: command)
      for target in written where isLiteral(target.path) {
        let path = target.path
        let underDirectories =
          path.hasPrefix("/") || path.hasPrefix("~") ? [] : directories.map { $0 + "/" + path }
        for spelling in [path] + underDirectories {
          let respelled = ShellWriteTarget(
            path: spelling, entries: target.entries, isDirectory: target.isDirectory)
          if !targets.contains(respelled) { targets.append(respelled) }
        }
      }
    }
    return targets
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
