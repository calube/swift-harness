extension ShellSyntax {
  /// Every path a command line may write, as spelled: output redirections, `tee`, the
  /// destinations of `cp`/`mv`/`install`/`ln` (and what `mv` moves away), the operands of
  /// `rm`/`rmdir`/`unlink`/`truncate`/`touch`, `dd of=`, and the files of `sed -i`/`perl -i`.
  /// A relative path is relative to the shell's starting directory; after a literal `cd`, it is
  /// also named under that directory. A path the shell would expand (`$VAR`, `$(…)`, backticks),
  /// code an interpreter runs, and heredoc text name nothing: a static reading can't know them.
  public static func writeTargets(in line: String) -> [String] {
    let commands = parse(line).filter { !$0.isHeredocBody }.map(\.command)
    let directories = commands.compactMap(changedDirectory)
    var targets: [String] = []
    for command in commands {
      for path in command.redirectTargets + writtenOperands(of: command) where isLiteral(path) {
        let underDirectories =
          path.hasPrefix("/") || path.hasPrefix("~") ? [] : directories.map { $0 + "/" + path }
        for spelling in [path] + underDirectories where !targets.contains(spelling) {
          targets.append(spelling)
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

  private static func writtenOperands(of command: SimpleCommand) -> [String] {
    let arguments = command.arguments
    switch command.name {
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
    case let name? where ["cp", "mv", "ln", "install", "ginstall"].contains(name):
      return copyDestinations(name, arguments)
    case "sed"?, "gsed"?:
      return sedFiles(arguments)
    case "perl"?:
      return perlFiles(arguments)
    default:
      return []
    }
  }

  private static let targetDirectoryOptions: Set<String> = ["-t", "--target-directory"]

  /// Where `cp`, `mv`, `ln` and `install` write: the destination, and each source's name inside
  /// it in case it is a directory. `mv` also removes its sources.
  private static func copyDestinations(_ name: String, _ arguments: [String]) -> [String] {
    var valued: Set<String> = targetDirectoryOptions.union(["-S", "--suffix"])
    if name.hasSuffix("install") {
      valued.formUnion(["-m", "-o", "-g", "-B", "-f", "--mode", "--owner", "--group"])
    }
    let scanned = scan(arguments, valued: valued)
    var operands = scanned.operands
    if name.hasSuffix("install"),
      arguments.contains(where: { $0 == "-d" || $0 == "--directory" })
    {
      return operands
    }
    let destination: String
    if let directory = scanned.values.last(where: { targetDirectoryOptions.contains($0.option) }) {
      destination = directory.value
    } else if operands.count >= 2 {
      destination = operands.removeLast()
    } else if name == "ln", let only = operands.first {
      return [basename(only)]
    } else {
      return []
    }
    var directory = Substring(destination)
    while directory.count > 1, directory.hasSuffix("/") { directory = directory.dropLast() }
    let inside = operands.map { directory + "/" + basename($0) }
    return [destination] + inside + (name == "mv" ? operands : [])
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
