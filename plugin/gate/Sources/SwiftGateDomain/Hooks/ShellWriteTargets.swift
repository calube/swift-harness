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
  /// A relative path is named under every directory its command may run in (see
  /// ``possibleDirectories(_:directoryExists:)``), the starting directory spelled as the bare
  /// path. Where the line can't be followed, it is relative to the starting directory and also
  /// named under every literal `cd` of the line, so a `cd` the shell may not have made never
  /// hides a write from the starting directory. A path the
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

  /// Commands that can move the shell, or define something that does, out of a static reading's
  /// sight. A line holding one at top level is read as if no `cd` were certain.
  private static let opaqueCommands: Set<String> = [
    "eval", "source", ".", "trap", "alias", "function", "builtin", "enable",
  ]
  private static let directoryCommands: Set<String> = ["cd", "pushd", "popd"]
  /// Words that open, continue or close a compound command, whose body may run any number of
  /// times or not at all.
  private static let compoundWords: Set<String> = [
    "if", "then", "else", "elif", "fi", "while", "until", "for", "select", "do", "done", "case",
    "esac", "{", "}",
  ]
  private static let compoundOpeners: Set<String> = [
    "if", "while", "until", "for", "select", "case", "{",
  ]
  private static let compoundClosers: Set<String> = ["fi", "done", "esac", "}"]

  /// Every directory each top-level command may run in, by index into `commands`, read in order
  /// as the shell runs them. A literal `cd` or `pushd` moves the shell to its operand, a relative
  /// one from each directory the shell may be in (as with `CDPATH` unset). Unless its directory
  /// exists now, or an earlier `mkdir -p` of the line made it on every path to the `cd`, the
  /// `cd` may fail and leave the shell where it was. A lone `mkdir -p` of literal paths is read
  /// as succeeding: it fails only on a path that is a file or can't be written. A command after `&&` runs
  /// where everything before it succeeded, after `||` where something failed, and after `;` or a
  /// newline wherever the shell may be; a pipeline's commands run in subshells that move nothing,
  /// and `exit` ends the shell.
  ///
  /// A compound command (`if`, `for`, `{ … }`) that holds no directory command or `exit` runs
  /// where it starts and leaves the shell there.
  ///
  /// A `cd` operand's `$NAME` or `${NAME}` reads the literal value an earlier assignment-only
  /// command of the line (`NAME=value`, or `export NAME=value`) gave it, when that command ran
  /// unconditionally on its own and no later command may have changed it: one inside a
  /// compound, joined by `&&` or `||`, in a pipeline, or naming the variable as a word
  /// (`read NAME`, `unset NAME`, `for NAME in`) leaves it unknown.
  ///
  /// A function definition (`name() { … }` or `function name { … }`) moves nothing where it
  /// stands, so the shell stays where it was; its body's commands have no entry, since they run
  /// wherever the function is called.
  ///
  /// From the first command a static reading can't follow on, the map has no entry: any other
  /// compound command, a subshell, a command sent to the background, or a `cd` to any other
  /// variable, a glob, `~` or `-`, behind `!` or through a wrapper like `env`. A line that runs
  /// `eval`, `source` or `trap` at top level, defines a function in any other form, or calls a
  /// function whose body may move or end the shell (or, while it defines one, calls a command
  /// named by an expansion) has no entries at all, and neither has a command no path reaches.
  static func possibleDirectories(
    _ commands: [ParsedCommand], directoryExists: (String) -> Bool
  ) -> [Int: [ShellDirectory]] {
    let top = commands.indices.filter { commands[$0].isTopLevel }
    let definitions = functionDefinitions(top, commands)
    let defined = definitions.reduce(into: Set<Int>()) { positions, definition in
      positions.formUnion(definition.header...definition.closer)
    }
    let opaque = top.indices.contains { position in
      guard !defined.contains(position) else { return false }
      let entry = commands[top[position]]
      let name = unwrapped(entry).name
      return name.map(opaqueCommands.contains) == true
        || zip(entry.links, entry.links.dropFirst()).contains { $0 == (.open, .close) }
    }
    guard !opaque, !callsMovingFunction(top, commands, definitions, outside: defined) else {
      return [:]
    }
    let closers = Dictionary(
      definitions.map { ($0.header, $0.closer) }, uniquingKeysWith: { first, _ in first })

    var possible: [Int: [ShellDirectory]] = [:]
    var variables: [String: String] = [:]
    var succeeded: [ShellDirectory] = [.start]
    var failed: [ShellDirectory] = []
    // The absolute directories a `mkdir -p` made on every path that ends in `succeeded`, and on
    // every path that ends in `failed`.
    var madeIfSucceeded: Set<String> = []
    var madeIfFailed: Set<String> = []
    var position = 0
    while position < top.count {
      guard let link = joining(commands[top[position]].links) else { break }
      let runs: [ShellDirectory]
      let made: Set<String>
      switch link {
      case .and: (runs, made) = (succeeded, madeIfSucceeded)
      case .or: (runs, made) = (failed, madeIfFailed)
      default:
        runs = merged(succeeded, failed)
        made = madeOnBoth(succeeded, madeIfSucceeded, failed, madeIfFailed)
      }
      if let opener = commands[top[position]].words.first, compoundOpeners.contains(opener) {
        guard let closer = staticCompound(top, from: position, commands) else { break }
        if !runs.isEmpty {
          for index in top[position...closer] { possible[index] = runs }
        }
        for index in top[position...closer] { forget(commands[index], in: &variables) }
        succeeded = runs
        failed = runs
        madeIfSucceeded = made
        madeIfFailed = made
        position = closer + 1
        continue
      }
      var end = position + 1
      let closer = closers[position]
      if let closer {
        end = closer + 1
      } else {
        while end < top.count, joining(commands[top[end]].links) == .pipe { end += 1 }
      }
      // A function definition runs nothing, so it stands for no pipeline.
      let pipeline = closer == nil ? top[position..<end].map { commands[$0] } : []
      guard
        pipeline.allSatisfy({ entry in
          entry.words.first.map(compoundWords.contains) != true
        })
      else { break }
      let after: (succeeded: [ShellDirectory], failed: [ShellDirectory])
      var madeAfter = made
      if pipeline.isEmpty {
        after = (runs, [])
      } else if pipeline.count > 1 {
        after = (runs, runs)
      } else if let operands = madeDirectories(pipeline[0], variables: variables) {
        for operand in operands {
          for directory in runs {
            if operand.hasPrefix("/") {
              madeAfter.insert(operand)
            } else if case .path(let base) = directory, base.hasPrefix("/") {
              madeAfter.insert(base + "/" + operand)
            }
          }
        }
        after = (runs, [])
      } else if isDirectoryCommand(pipeline[0]) {
        guard let operand = certainDirectory(pipeline[0], variables: variables) else { break }
        let moved = merged(
          runs.map { directory in
            guard case .path(let base) = directory, !operand.hasPrefix("/") else {
              return .path(operand)
            }
            return .path(base + "/" + operand)
          }, [])
        let certain = moved.allSatisfy { directory in
          guard case .path(let path) = directory else { return false }
          return path.hasPrefix("/")
            && (directoryExists(path) || made.contains { $0 == path || $0.hasPrefix(path + "/") })
        }
        after = (moved, certain ? [] : runs)
      } else if unwrapped(pipeline[0]).name == "exit" {
        after = ([], [])
      } else {
        after = (runs, runs)
      }
      if !runs.isEmpty, !pipeline.isEmpty {
        for index in top[position..<end] { possible[index] = runs }
      }
      if pipeline.count == 1, link == .sequence, let assigned = assignments(pipeline[0]) {
        for (name, value) in assigned {
          variables[name] = value.flatMap { expanded($0, variables) }.flatMap { value in
            value.contains(where: \.isWhitespace) ? nil : value
          }
        }
      } else {
        for entry in pipeline { forget(entry, in: &variables) }
      }
      switch link {
      case .and:
        madeIfFailed = madeOnBoth(failed, madeIfFailed, after.failed, madeAfter)
        madeIfSucceeded = madeAfter
        succeeded = after.succeeded
        failed = merged(failed, after.failed)
      case .or:
        madeIfSucceeded = madeOnBoth(succeeded, madeIfSucceeded, after.succeeded, madeAfter)
        madeIfFailed = madeAfter
        succeeded = merged(succeeded, after.succeeded)
        failed = after.failed
      default:
        madeIfSucceeded = madeAfter
        madeIfFailed = madeAfter
        succeeded = after.succeeded
        failed = after.failed
      }
      position = end
    }
    return possible
  }

  /// The directory each top-level command certainly runs in, by index into `commands`: the one
  /// absolute directory ``possibleDirectories(_:directoryExists:)`` leaves it.
  static func knownDirectories(
    _ commands: [ParsedCommand], directoryExists: (String) -> Bool
  ) -> [Int: String] {
    possibleDirectories(commands, directoryExists: directoryExists).compactMapValues {
      guard $0.count == 1, case .path(let path) = $0[0], path.hasPrefix("/") else { return nil }
      return path
    }
  }

  /// A function definition at top level, by position in `top`.
  private struct FunctionDefinition {
    let name: String
    /// The command that names the function.
    let header: Int
    /// The command that opens the body: the `{` after `name()`, or `header` itself for
    /// `function name { …`.
    let brace: Int
    /// The `}` that closes the body.
    let closer: Int
  }

  /// Every `name() { … }`, `name () { … }`, `function name { … }` and `function name() { … }` at
  /// top level whose body closes with a lone `}` that nothing redirects, pipes or sends to the
  /// background. A definition in any other form is not one of them.
  private static func functionDefinitions(_ top: [Int], _ commands: [ParsedCommand])
    -> [FunctionDefinition]
  {
    var definitions: [FunctionDefinition] = []
    var position = 0
    while position < top.count {
      let words = commands[top[position]].words
      let next = position + 1 < top.count ? commands[top[position + 1]] : nil
      // Whether `next` is the `{` that opens a body after `()` or, with `parenthesized` false,
      // after a newline.
      let opensBody = { (parenthesized: Bool) -> Bool in
        guard let next, next.words.first == "{" else { return false }
        let prefix: [ShellLink] = parenthesized ? [.open, .close] : [.sequence]
        return next.links.starts(with: prefix)
          && next.links.dropFirst(prefix.count).allSatisfy { $0 == .sequence }
      }
      var found: (name: String, brace: Int)?
      if words.count == 1, isFunctionName(words[0]), opensBody(true) {
        found = (words[0], position + 1)
      } else if words.first == "function", words.count >= 2, isFunctionName(words[1]) {
        if words.count >= 3, words[2] == "{" {
          found = (words[1], position)
        } else if words.count == 2, opensBody(true) || opensBody(false) {
          found = (words[1], position + 1)
        }
      }
      if let found, commands[top[position]].command.redirectTargets.isEmpty,
        let closer = bodyCloser(top, brace: found.brace, commands)
      {
        definitions.append(
          FunctionDefinition(name: found.name, header: position, brace: found.brace, closer: closer)
        )
        position = closer + 1
      } else {
        position += 1
      }
    }
    return definitions
  }

  /// The position in `top` of the lone `}` that closes the function body opening at `brace`.
  private static func bodyCloser(_ top: [Int], brace: Int, _ commands: [ParsedCommand]) -> Int? {
    var depth = 0
    for current in brace..<top.count {
      for word in bodyWords(commands[top[current]], isBrace: current == brace)
        .prefix(while: compoundWords.contains)
      {
        if compoundOpeners.contains(word) { depth += 1 }
        if compoundClosers.contains(word) { depth -= 1 }
      }
      guard depth <= 0, current > brace else { continue }
      let entry = commands[top[current]]
      let after = current + 1 < top.count ? commands[top[current + 1]].links : []
      guard depth == 0, entry.words == ["}"], entry.command.redirectTargets.isEmpty,
        !after.contains(where: { $0 == .pipe || $0 == .background })
      else { return nil }
      return current
    }
    return nil
  }

  /// A body command's words, from the `{` on for the command that opens the body.
  private static func bodyWords(_ entry: ParsedCommand, isBrace: Bool) -> ArraySlice<String> {
    guard isBrace, let open = entry.words.firstIndex(of: "{") else { return entry.words[...] }
    return entry.words[open...]
  }

  private static func isFunctionName(_ word: String) -> Bool {
    !word.isEmpty && !compoundWords.contains(word)
      && word.allSatisfy {
        $0 == "_" || $0 == "-" || $0 == "." || $0 == ":"
          || ($0.isASCII && ($0.isLetter || $0.isNumber))
      }
  }

  /// Whether the line's shell calls a function whose body may move or end it: one with a
  /// directory command, `exit`, `eval`-like command, nested definition, command named by an
  /// expansion, or call to such a function. A call is a top-level command at a position in `top`
  /// outside `defined`, by the function's name or, once any function moves, by an expansion; a
  /// call in a command substitution runs in a subshell and moves nothing.
  private static func callsMovingFunction(
    _ top: [Int], _ commands: [ParsedCommand], _ definitions: [FunctionDefinition],
    outside defined: Set<Int>
  ) -> Bool {
    guard !definitions.isEmpty else { return false }
    let name = { (entry: ParsedCommand, isBrace: Bool) -> String? in
      normalize(
        Array(bodyWords(entry, isBrace: isBrace).drop { compoundWords.contains($0) || $0 == "!" })
      )
      .name
    }
    let isExpansion = { (name: String) in name.contains("$") || name.contains("`") }
    var moving: Set<String> = []
    while true {
      let before = moving.count
      for definition in definitions where !moving.contains(definition.name) {
        let moves = (definition.brace...definition.closer).contains { position in
          let entry = commands[top[position]]
          guard let called = name(entry, position == definition.brace) else { return false }
          return directoryCommands.contains(called) || opaqueCommands.contains(called)
            || called == "exit" || isExpansion(called) || moving.contains(called)
            || (position != definition.brace
              && zip(entry.links, entry.links.dropFirst()).contains { $0 == (.open, .close) })
        }
        if moves { moving.insert(definition.name) }
      }
      if moving.count == before { break }
    }
    guard !moving.isEmpty else { return false }
    return top.indices.contains { position in
      guard !defined.contains(position), let called = name(commands[top[position]], false) else {
        return false
      }
      return moving.contains(called) || isExpansion(called)
    }
  }

  /// The position in `top` of the word that closes the compound command opening at `position`,
  /// when nothing inside it can move or end the shell: no directory command, `exit`, subshell or
  /// background command. Its commands then run where it starts, and leave the shell there.
  private static func staticCompound(
    _ top: [Int], from position: Int, _ commands: [ParsedCommand]
  ) -> Int? {
    var depth = 0
    for current in position..<top.count {
      let entry = commands[top[current]]
      if current > position, joining(entry.links) == nil { return nil }
      if isDirectoryCommand(entry) || unwrapped(entry).name == "exit" { return nil }
      guard let word = entry.words.first else { continue }
      if compoundOpeners.contains(word) { depth += 1 }
      if compoundClosers.contains(word) {
        depth -= 1
        if depth == 0 { return current }
      }
    }
    return nil
  }

  /// The operator that joins a command to the one before it, a newline after `&&`, `||` or `|`
  /// only continuing it. `nil` for a subshell's bounds or a command sent to the background.
  private static func joining(_ links: [ShellLink]) -> ShellLink? {
    if links.contains(where: { $0 == .open || $0 == .close || $0 == .background }) { return nil }
    return links.first { $0 != .sequence } ?? .sequence
  }

  /// What a `mkdir -p` made on every path of both `first` and `second`, each with the directories
  /// made on its paths; a side no path reaches constrains nothing.
  private static func madeOnBoth(
    _ first: [ShellDirectory], _ madeOnFirst: Set<String>,
    _ second: [ShellDirectory], _ madeOnSecond: Set<String>
  ) -> Set<String> {
    if first.isEmpty { return madeOnSecond }
    if second.isEmpty { return madeOnFirst }
    return madeOnFirst.intersection(madeOnSecond)
  }

  /// The operands of a plain `mkdir -p` (or `--parents`) whose every operand is 1 literal path
  /// after `variables` are expanded, without trailing slashes; `nil` for any other command.
  private static func madeDirectories(_ entry: ParsedCommand, variables: [String: String])
    -> [String]?
  {
    guard entry.words.first == "mkdir" else { return nil }
    let arguments = Array(entry.words.dropFirst())
    let parents = arguments.prefix { $0 != "--" }.contains { argument in
      argument == "--parents"
        || (argument.hasPrefix("-") && !argument.hasPrefix("--")
          && argument.dropFirst().prefix { $0 != "m" }.contains("p"))
    }
    let operands = scan(arguments, valued: ["-m", "--mode"]).operands
    guard parents, !operands.isEmpty else { return nil }
    var directories: [String] = []
    for operand in operands {
      guard let directory = expanded(operand, variables),
        !directory.contains(where: { "*?[{~\\".contains($0) })
      else { return nil }
      var trimmed = Substring(directory)
      while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
      directories.append(String(trimmed))
    }
    return directories
  }

  /// `first` then the directories of `second` it lacks, in order.
  private static func merged(_ first: [ShellDirectory], _ second: [ShellDirectory])
    -> [ShellDirectory]
  {
    var result: [ShellDirectory] = []
    for directory in first + second where !result.contains(directory) {
      result.append(directory)
    }
    return result
  }

  /// The words after any compound-command words and `!`, re-read as a simple command.
  private static func unwrapped(_ entry: ParsedCommand) -> SimpleCommand {
    normalize(Array(entry.words.drop { compoundWords.contains($0) || $0 == "!" }))
  }

  private static func isDirectoryCommand(_ entry: ParsedCommand) -> Bool {
    unwrapped(entry).name.map(directoryCommands.contains) == true
  }

  /// The operand of a plain `cd` or `pushd` to 1 literal path, without trailing slashes, after
  /// `variables` are expanded in it; `nil` for any other command, for `cd -`, `~`, a glob or
  /// any other expansion, and for a `cd` behind `!`, a wrapper or an assignment.
  private static func certainDirectory(_ entry: ParsedCommand, variables: [String: String])
    -> String?
  {
    guard let name = entry.words.first else { return nil }
    let options: Set<String>
    switch name {
    case "cd": options = ["-L", "-P", "--"]
    case "pushd": options = ["--"]
    default: return nil
    }
    let operands = entry.words.dropFirst().drop { options.contains($0) }
    guard operands.count == 1, let directory = operands.first.flatMap({ expanded($0, variables) }),
      !directory.contains(where: { "*?[{~\\".contains($0) })
    else { return nil }
    var trimmed = Substring(directory)
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
    return String(trimmed)
  }

  /// The variables an assignment-only command sets, each with its value as spelled, `nil` for
  /// an `export` without one; `nil` for any other command.
  private static func assignments(_ entry: ParsedCommand) -> [(String, String?)]? {
    var words = entry.words[...]
    let exported = words.first == "export"
    if exported { words = words.dropFirst() }
    guard !words.isEmpty else { return nil }
    var result: [(String, String?)] = []
    for word in words {
      if isAssignment(word) {
        let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        result.append((String(parts[0]), String(parts[1])))
      } else if exported, isVariableName(word) {
        result.append((word, nil))
      } else {
        return nil
      }
    }
    return result
  }

  /// Drops from `variables` each name `entry` spells as a word or assigns, since it may set it.
  private static func forget(_ entry: ParsedCommand, in variables: inout [String: String]) {
    for word in entry.words {
      let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
      variables[name] = nil
    }
  }

  private static func isVariableName(_ word: some StringProtocol) -> Bool {
    guard let head = word.first, head == "_" || (head.isASCII && head.isLetter) else {
      return false
    }
    return word.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
  }

  /// `word` with each `$NAME` and `${NAME}` it holds replaced by that name's value in
  /// `variables`; `nil` when any other expansion is left or the result is empty.
  private static func expanded(_ word: String, _ variables: [String: String]) -> String? {
    var result = ""
    var rest = Substring(word)
    while let dollar = rest.firstIndex(of: "$") {
      result += rest[..<dollar]
      var after = rest[rest.index(after: dollar)...]
      let braced = after.first == "{"
      if braced { after = after.dropFirst() }
      let name = after.prefix { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
      guard isVariableName(name), let value = variables[String(name)] else { return nil }
      after = after.dropFirst(name.count)
      if braced {
        guard after.first == "}" else { return nil }
        after = after.dropFirst()
      }
      result += value
      rest = after
    }
    result += rest
    return isLiteral(result) ? result : nil
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
