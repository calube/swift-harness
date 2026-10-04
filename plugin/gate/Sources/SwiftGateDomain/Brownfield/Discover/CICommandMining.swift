import Foundation

/// 1 command a CI workflow, `Makefile`, `justfile` or `bin/*` script already runs, attributed to
/// 1 area and step.
public struct MinedCommand: Sendable, Equatable {
  public let area: String
  public let step: AreaStep
  /// Runnable from the area root.
  public let command: String
  /// Repository-relative path of the file that runs it, with a note when the command could not
  /// be rebased onto the area root.
  public let source: String
  /// `.found` when the command runs from the area root as CI runs it; `.guessed` when it only
  /// reaches the area by changing back to where CI ran it.
  public let confidence: Confidence

  public init(
    area: String, step: AreaStep, command: String, source: String,
    confidence: Confidence = .found
  ) {
    self.area = area
    self.step = step
    self.command = command
    self.source = source
    self.confidence = confidence
  }
}

/// Finds the test, lint and build commands a repository already runs, which outrank a reader's
/// guess (design §5.1).
///
/// A command is kept only when its step and its area are both unambiguous: it starts with a tool
/// this knows, exactly 1 of the test, lint and build words appears in it, and 1 area claims it,
/// by the directory it runs in, a directory or package it names, or as the only area at the root
/// whose kind runs that tool. A command run in a directory no nested area holds is left out, not
/// given to the root area. Anything else is left for the reader's own value.
public enum CICommandMining {
  /// Every attributable command in `tree`, CI workflows first, then `Makefile`, `justfile` and
  /// `bin/*`, each group in path order.
  public static func commands(in tree: TrackedTreeSnapshot, areas: [ProposedArea])
    -> [MinedCommand]
  {
    let paths = tree.paths.sorted()
    var candidates: [Candidate] = []
    for path in paths where isWorkflow(path) {
      guard let text = tree.read(path).map({ String(decoding: $0, as: UTF8.self) }) else {
        continue
      }
      candidates += WorkflowRuns.runs(in: text).flatMap { run in
        ShellSegments.candidates(script: run.script, directory: run.directory, source: path)
          .map { $0.inEnvironment(run.environment) }
      }
    }
    for path in paths where ["Makefile", "makefile", "GNUmakefile"].contains(basename(path)) {
      guard let text = tree.read(path).map({ String(decoding: $0, as: UTF8.self) }) else {
        continue
      }
      let directory = dirname(path)
      for target in makeTargets(text) {
        candidates.append(
          Candidate(
            step: target, segment: "make \(target.rawValue)", cwd: directory,
            directory: directory, kinds: nil, names: [], source: path))
      }
    }
    for path in paths where ["justfile", "Justfile", ".justfile"].contains(basename(path)) {
      guard let text = tree.read(path).map({ String(decoding: $0, as: UTF8.self) }) else {
        continue
      }
      let directory = dirname(path)
      for recipe in justRecipes(text) {
        candidates.append(
          Candidate(
            step: recipe, segment: "just \(recipe.rawValue)", cwd: directory,
            directory: directory, kinds: nil, names: [], source: path))
      }
    }
    for path in paths {
      let parts = path.split(separator: "/").map(String.init)
      guard parts.count >= 2, parts[parts.count - 2] == "bin",
        let step = stepWords[parts[parts.count - 1]]
      else { continue }
      let directory = parts.count == 2 ? "." : parts.dropLast(2).joined(separator: "/")
      candidates.append(
        Candidate(
          step: step, segment: "bin/\(parts[parts.count - 1])", cwd: directory,
          directory: directory, kinds: nil, names: [], source: path))
    }
    return candidates.compactMap { candidate in
      guard let area = attribute(candidate, to: areas) else { return nil }
      let note =
        candidate.leftOut.isEmpty ? "" : " (\(WorkflowEnvironment.note(candidate.leftOut)))"
      if let command = candidate.retarget?(area.root) {
        return MinedCommand(
          area: area.name, step: candidate.step, command: candidate.withEnvironment(command),
          source: candidate.source + note)
      }
      let command = inDirectory(
        relative(candidate.cwd, to: area.root), candidate.withEnvironment(candidate.segment))
      guard contains(area.root, candidate.cwd) else {
        return MinedCommand(
          area: area.name, step: candidate.step, command: command,
          source: candidate.source + " (runs from the repository root)" + note,
          confidence: .guessed)
      }
      return MinedCommand(
        area: area.name, step: candidate.step, command: command, source: candidate.source + note)
    }
  }

  /// `areas` with the first found mined command for each area and step replacing a guessed value
  /// or filling a missing one. A value a build file states stays. A guessed mined command, 1 that
  /// only runs from the repository root, fills a missing step and replaces nothing.
  public static func outrank(_ areas: [ProposedArea], with mined: [MinedCommand])
    -> [ProposedArea]
  {
    areas.map { area in
      var commands = area.commands
      var missing = area.missing
      let own = mined.filter { $0.area == area.name }
      let found = own.filter { $0.confidence == .found }
      var settled: Set<AreaStep> = []
      for command in found + own.filter({ $0.confidence == .guessed }) {
        guard settled.insert(command.step).inserted else { continue }
        if let current = commands[command.step] {
          guard current.confidence == .guessed, command.confidence == .found else { continue }
        }
        commands[command.step] = Sourced(
          value: command.command, source: command.source, confidence: command.confidence)
        missing[command.step] = nil
      }
      return area.replacing(commands: commands, missing: missing)
    }
  }

  // MARK: - Attribution

  struct Candidate {
    let step: AreaStep
    /// The command as CI runs it from `cwd`.
    let segment: String
    /// Where CI runs it, repository-relative.
    let cwd: String
    /// Where the command acts, repository-relative.
    let directory: String
    /// The area kinds whose tool it runs; `nil` for a runner of any kind, such as `make`.
    let kinds: Set<AreaKind>?
    /// Package names it selects, such as `cargo test -p core`.
    let names: [String]
    let source: String
    /// The command with its directory flag pointed at the area root it is given, so it runs from
    /// there; `nil` when it has no directory flag or the flag points outside that root.
    var retarget: ((String) -> String?)? = nil
    /// The workflow's `env:` in effect for the step, less the names the command assigns itself.
    var environment: [WorkflowEnvironment.Variable] = []
    /// What the step's `env:` set that the command can't carry.
    var leftOut: [WorkflowEnvironment.LeftOut] = []

    /// This candidate run with `environment`: a name the command assigns itself keeps its own
    /// value, as the shell gives it.
    func inEnvironment(_ environment: WorkflowEnvironment) -> Candidate {
      let assigned = Set(
        segment.split(separator: " ").prefix { $0.contains("=") && !$0.hasPrefix("-") }
          .map { String($0.prefix { $0 != "=" }) })
      var copy = self
      copy.environment = environment.variables.filter { !assigned.contains($0.name) }
      copy.leftOut = environment.leftOut.filter { !assigned.contains($0.name) }
      return copy
    }

    func withEnvironment(_ command: String) -> String {
      let assignments = environment.map { "\($0.name)=\(WorkflowEnvironment.quote($0.value))" }
      return (assignments + [command]).joined(separator: " ")
    }
  }

  static func attribute(_ candidate: Candidate, to areas: [ProposedArea]) -> ProposedArea? {
    let compatible = areas.filter { candidate.kinds?.contains($0.kind) ?? true }
    if !candidate.names.isEmpty {
      let named = compatible.filter { area in
        candidate.names.contains { name in
          name == area.name
            || name.split(separator: "/").last.map(String.init) == basename(area.root)
        }
      }
      return named.count == 1 ? named[0] : nil
    }
    let directory = candidate.directory
    if directory != "." {
      let containing = areas.filter {
        $0.root != "." && (directory == $0.root || directory.hasPrefix($0.root + "/"))
      }
      guard let longest = containing.map(\.root.count).max() else { return nil }
      let deepest = containing.filter { $0.root.count == longest }
      let fitting = deepest.filter { candidate.kinds?.contains($0.kind) ?? true }
      return fitting.count == 1 ? fitting[0] : nil
    }
    let atRoot = compatible.filter { $0.root == "." }
    return atRoot.count == 1 ? atRoot[0] : nil
  }

  // MARK: - Words

  static let stepWords: [String: AreaStep] = [
    "test": .test, "pytest": .test, "rspec": .test, "ctest": .test, "nextest": .test,
    "lint": .lint, "eslint": .lint, "ruff": .lint, "clippy": .lint, "golangci-lint": .lint,
    "rubocop": .lint, "swiftlint": .lint, "credo": .lint, "flake8": .lint, "pylint": .lint,
    "ktlint": .lint, "detekt": .lint, "biome": .lint, "standardrb": .lint, "stylelint": .lint,
    "build": .build, "assemble": .build,
  ]

  /// Words that make a command a setup step whatever else it names, such as
  /// `npm install eslint`.
  static let setupWords: Set<String> = [
    "install", "i", "ci", "add", "uninstall", "remove", "update", "upgrade", "sync", "setup",
    "publish", "version", "init",
  ]

  /// The tools a command may start with, and the area kinds each one serves; `nil` serves any.
  static let tools: [String: Set<AreaKind>?] = {
    var tools: [String: Set<AreaKind>?] = [:]
    for tool in ["npm", "npx", "pnpm", "yarn", "bun", "bunx", "node", "turbo", "nx"] {
      tools[tool] = [.node]
    }
    for tool in ["cargo", "cross"] { tools[tool] = [.cargo] }
    for tool in ["go", "golangci-lint"] { tools[tool] = [.go] }
    for tool in ["swift", "swiftlint", "swift-format"] { tools[tool] = [.swiftpm, .xcode] }
    for tool in ["xcodebuild", "xcodegen", "tuist", "fastlane"] { tools[tool] = [.xcode] }
    for tool in [
      "python", "python3", "pytest", "uv", "tox", "nox", "ruff", "flake8", "pylint", "mypy",
      "poetry", "pdm", "hatch",
    ] {
      tools[tool] = [.python]
    }
    for tool in ["gradle", "gradlew", "mvn", "mvnw"] { tools[tool] = [.jvm] }
    for tool in ["bundle", "rake", "rspec", "rubocop", "rails", "mix", "cmake", "ctest"] {
      tools[tool] = [.command]
    }
    for tool in ["make", "just"] { tools[tool] = .some(nil) }
    return tools
  }()

  // MARK: - Files

  static func isWorkflow(_ path: String) -> Bool {
    let parts = path.split(separator: "/")
    guard parts.count == 3, parts[0] == ".github", parts[1] == "workflows" else { return false }
    return path.hasSuffix(".yml") || path.hasSuffix(".yaml")
  }

  static func makeTargets(_ text: String) -> [AreaStep] {
    ruleNames(text, allowAt: false)
  }

  static func justRecipes(_ text: String) -> [AreaStep] {
    ruleNames(text, allowAt: true)
  }

  /// The `test`, `lint` and `build` rules a `Makefile` or `justfile` defines: a line starting at
  /// column 0 with the name, then parameters or nothing, then a `:` that isn't `:=`.
  private static func ruleNames(_ text: String, allowAt: Bool) -> [AreaStep] {
    var found: [AreaStep] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
      var rest = Substring(line)
      if allowAt, rest.first == "@" { rest = rest.dropFirst() }
      let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
      guard !name.isEmpty, let step = stepWords[String(name)],
        [.test, .lint, .build].contains(step),
        String(name) == step.rawValue
      else { continue }
      let after = rest.dropFirst(name.count)
      guard let colon = after.firstIndex(of: ":"), !after[..<colon].contains("=") else { continue }
      if after[after.index(after: colon)...].first == "=" { continue }
      if !found.contains(step) { found.append(step) }
    }
    return found
  }

  // MARK: - Paths

  static func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }

  static func dirname(_ path: String) -> String {
    let parts = path.split(separator: "/")
    return parts.count <= 1 ? "." : parts.dropLast().joined(separator: "/")
  }

  /// `relative` resolved against `base`, both repository-relative; `nil` when it leaves the
  /// repository or is absolute.
  static func join(_ base: String, _ relative: String) -> String? {
    guard !relative.hasPrefix("/"), !relative.hasPrefix("~"), !relative.contains("$") else {
      return nil
    }
    var parts = base == "." ? [] : base.split(separator: "/").map(String.init)
    for part in relative.split(separator: "/") {
      switch part {
      case ".": continue
      case "..":
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
      default: parts.append(String(part))
      }
    }
    return parts.isEmpty ? "." : parts.joined(separator: "/")
  }

  /// Whether repository-relative `path` is `root` or inside it.
  static func contains(_ root: String, _ path: String) -> Bool {
    root == "." || path == root || path.hasPrefix(root + "/")
  }

  /// Repository-relative `path` as seen from repository-relative `root`, climbing with `..`.
  static func relative(_ path: String, to root: String) -> String {
    let parts = path.split(separator: "/").filter { $0 != "." }
    let base = root.split(separator: "/").filter { $0 != "." }
    let shared = zip(parts, base).prefix { $0 == $1 }.count
    let steps = Array(repeating: "..", count: base.count - shared) + parts.dropFirst(shared)
    return steps.isEmpty ? "." : steps.joined(separator: "/")
  }

  static func quote(_ path: String) -> String {
    path.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" })
      ? "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" : path
  }

  static func inDirectory(_ directory: String, _ command: String) -> String {
    directory == "." ? command : "cd \(quote(directory)) && \(command)"
  }
}

/// The `run:` scripts of a GitHub Actions workflow, each with its step's `working-directory`, or
/// else its job's or the workflow's `defaults.run.working-directory`. A line reader, not a YAML parser: it reads the keys of each list item at the item's own
/// column, which is how every workflow writes a step.
enum WorkflowRuns {
  struct Run: Equatable {
    let script: [String]
    let directory: String
    let environment: WorkflowEnvironment
  }

  static func runs(in text: String) -> [Run] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let defaults = defaultDirectories(lines)
    let scopes = environmentScopes(lines)
    var runs: [Run] = []
    for (index, line) in lines.enumerated() {
      let indent = line.prefix { $0 == " " }.count
      let rest = line.dropFirst(indent)
      guard rest.hasPrefix("- ") else { continue }
      let column = indent + 2 + rest.dropFirst(2).prefix { $0 == " " }.count
      var end = index + 1
      while end < lines.count, isBlank(lines[end]) || leading(lines[end]) > indent { end += 1 }
      let item = Array(lines[index..<end])
      var keyed: [(key: String, value: String, line: Int)] = []
      for (offset, itemLine) in item.enumerated() {
        let text = offset == 0 ? String(line.dropFirst(column)) : itemLine
        if offset > 0, leading(itemLine) != column { continue }
        let content = text.trimmingCharacters(in: .whitespaces)
        guard let colon = content.firstIndex(of: ":") else { continue }
        let key = String(content[..<colon])
        guard ["run", "working-directory", "env"].contains(key) else { continue }
        keyed.append(
          (
            key, content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces),
            offset
          ))
      }
      guard let run = keyed.first(where: { $0.key == "run" }) else { continue }
      let own = keyed.first(where: { $0.key == "working-directory" })?.value
      guard
        let directory = own.map({ CICommandMining.join(".", unquoted(stripComment($0))) })
          ?? defaults(index)
      else { continue }
      let script: [String]
      let value = stripComment(run.value)
      if value.hasPrefix("|") || value.hasPrefix(">") {
        let body = item[(run.line + 1)...].prefix { isBlank($0) || leading($0) > column }
        let depth = body.filter { !isBlank($0) }.map(leading).min() ?? 0
        script = body.map { isBlank($0) ? "" : String($0.dropFirst(depth)) }
      } else {
        script = [unquoted(value)]
      }
      var environment = scopes(index)
      if let env = keyed.first(where: { $0.key == "env" }) {
        let entries =
          env.value.isEmpty
          ? mapEntries(item[(env.line + 1)...], deeperThan: column) : nil
        environment = environment.narrowed(by: entries, scope: "step")
      }
      runs.append(Run(script: script, directory: directory, environment: environment))
    }
    return runs
  }

  /// The `env:` of the workflow and of the job holding each line, the job's over the
  /// workflow's.
  private static func environmentScopes(_ lines: [String]) -> (Int) -> WorkflowEnvironment {
    let workflow = WorkflowEnvironment().narrowed(
      by: scopeEnv(lines, in: 0..<lines.count, indent: 0), scope: "workflow")
    let jobs = jobSpans(lines).map { job in
      (
        span: job.span,
        environment: job.child.map {
          workflow.narrowed(by: scopeEnv(lines, in: job.span.dropFirst(), indent: $0), scope: "job")
        } ?? workflow
      )
    }
    return { index in jobs.first { $0.span.contains(index) }?.environment ?? workflow }
  }

  /// The entries of the `env:` key at `indent` within `span`: `[]` when there is none, `nil` when
  /// it is written inline, which this line reader can't read.
  private static func scopeEnv(_ lines: [String], in span: Range<Int>, indent: Int)
    -> [(name: String, value: String)]?
  {
    guard
      let start = span.first(where: {
        leading(lines[$0]) == indent && lines[$0].dropFirst(indent).hasPrefix("env:")
      })
    else { return [] }
    let inline = stripComment(
      lines[start].dropFirst(indent + "env:".count).trimmingCharacters(in: .whitespaces))
    guard inline.isEmpty else { return nil }
    return mapEntries(lines[(start + 1)..<span.upperBound], deeperThan: indent)
  }

  /// The `KEY: value` lines of the mapping that opens on the lines after its key, as written but
  /// unquoted, stopping at the first line no deeper than `indent`.
  private static func mapEntries(_ lines: ArraySlice<String>, deeperThan indent: Int)
    -> [(name: String, value: String)]
  {
    let body = lines.prefix { isBlank($0) || isComment($0) || leading($0) > indent }
      .filter { !isBlank($0) && !isComment($0) }
    guard let column = body.first.map(leading) else { return [] }
    return body.filter { leading($0) == column }.compactMap { line in
      let content = line.dropFirst(column)
      guard let colon = content.firstIndex(of: ":") else { return nil }
      let name = unquoted(String(content[..<colon]).trimmingCharacters(in: .whitespaces))
      let value = content[content.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      return (name, unquoted(stripComment(value)))
    }
  }

  /// The default directory of the step at each line: its job's `defaults.run.working-directory`,
  /// else the workflow's, else `.`; `nil` when the default leaves the repository.
  private static func defaultDirectories(_ lines: [String]) -> (Int) -> String? {
    let workflow = defaultDirectory(lines, in: 0..<lines.count, indent: 0)
    let jobs: [(span: Range<Int>, directory: String)] = jobSpans(lines).compactMap { job in
      guard let child = job.child,
        let directory = defaultDirectory(lines, in: job.span.dropFirst(), indent: child)
      else { return nil }
      return (job.span, directory)
    }
    return { index in
      CICommandMining.join(
        ".", jobs.first { $0.span.contains(index) }?.directory ?? workflow ?? ".")
    }
  }

  /// Each job under `jobs:`, from its key line to the next job's, with the column of its own keys.
  private static func jobSpans(_ lines: [String]) -> [(span: Range<Int>, child: Int?)] {
    guard let start = lines.firstIndex(where: { $0.hasPrefix("jobs:") }) else { return [] }
    let next = lines[(start + 1)...].firstIndex(where: { !isBlank($0) && leading($0) == 0 })
    let body = (start + 1)..<(next ?? lines.count)
    let keys = body.filter { !isBlank(lines[$0]) && !isComment(lines[$0]) }
    let column = keys.first.map { leading(lines[$0]) } ?? 0
    let starts = keys.filter { leading(lines[$0]) == column }
    return starts.enumerated().map { offset, jobStart in
      let end = offset + 1 < starts.count ? starts[offset + 1] : body.upperBound
      let child = ((jobStart + 1)..<end).first { !isBlank(lines[$0]) && !isComment(lines[$0]) }
        .map { leading(lines[$0]) }
      return (jobStart..<end, child)
    }
  }

  /// The `working-directory` under a `defaults:` key at `indent` within `span`, then `run:`, as
  /// written.
  private static func defaultDirectory(_ lines: [String], in span: Range<Int>, indent: Int)
    -> String?
  {
    guard
      let start = span.first(where: {
        leading(lines[$0]) == indent && lines[$0].dropFirst(indent).hasPrefix("defaults:")
      })
    else { return nil }
    var run: Int?
    for line in lines[(start + 1)..<span.upperBound] where !isBlank(line) && !isComment(line) {
      let column = leading(line)
      if column <= indent { break }
      let content = line.dropFirst(column)
      if let runColumn = run {
        if column <= runColumn {
          if content.hasPrefix("run:") { run = column } else { run = nil }
          continue
        }
        guard content.hasPrefix("working-directory:") else { continue }
        let value = content.dropFirst("working-directory:".count)
          .trimmingCharacters(in: .whitespaces)
        return unquoted(stripComment(value))
      } else if content.hasPrefix("run:") {
        run = column
      }
    }
    return nil
  }

  private static func isComment(_ line: String) -> Bool {
    line.drop { $0 == " " }.hasPrefix("#")
  }

  private static func leading(_ line: String) -> Int { line.prefix { $0 == " " }.count }

  private static func isBlank(_ line: String) -> Bool {
    line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
  }

  private static func stripComment(_ value: String) -> String {
    guard let hash = value.range(of: " #") else { return value }
    return value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
  }

  private static func unquoted(_ value: String) -> String {
    for quote in ["\"", "'"]
    where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
      return String(value.dropFirst().dropLast())
    }
    return value
  }
}

/// Splits a shell script into the commands it runs and keeps the ones a step word marks.
enum ShellSegments {
  static func candidates(script: [String], directory: String, source: String)
    -> [CICommandMining.Candidate]
  {
    var joined: [String] = []
    var pending = ""
    for line in script {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasSuffix("\\") {
        pending += trimmed.dropLast() + " "
      } else {
        joined.append(pending + trimmed)
        pending = ""
      }
    }
    if !pending.isEmpty { joined.append(pending) }

    var cwd: String? = directory
    var found: [CICommandMining.Candidate] = []
    for line in joined where !line.hasPrefix("#") {
      for segment in split(line) {
        let words = segment.split(separator: " ").map(String.init)
        if words.first == "cd" {
          cwd = words.count == 2 ? cwd.flatMap { CICommandMining.join($0, words[1]) } : nil
          continue
        }
        guard let cwd, let candidate = candidate(segment, words: words, cwd: cwd, source: source)
        else { continue }
        found.append(candidate)
      }
    }
    return found
  }

  /// A line's commands, split at `&&`, `||`, `;` and `|`, outside quotes.
  static func split(_ line: String) -> [String] {
    var segments: [String] = []
    var current = ""
    var quote: Character?
    var index = line.startIndex
    while index < line.endIndex {
      let character = line[index]
      if let open = quote {
        if character == open { quote = nil }
        current.append(character)
      } else if character == "\"" || character == "'" {
        quote = character
        current.append(character)
      } else if character == ";" || character == "|" || character == "&" {
        segments.append(current)
        current = ""
        let next = line.index(after: index)
        if next < line.endIndex, line[next] == character { index = next }
      } else {
        current.append(character)
      }
      index = line.index(after: index)
    }
    segments.append(current)
    return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  static func candidate(_ segment: String, words allWords: [String], cwd: String, source: String)
    -> CICommandMining.Candidate?
  {
    // A variable, a Windows variable or a Windows line continuation means the command only runs
    // inside CI's own environment.
    guard !segment.contains("$"), !segment.contains("%"), !segment.hasSuffix("^"),
      !segment.hasSuffix("`")
    else { return nil }
    var words = allWords.drop { $0.contains("=") && !$0.hasPrefix("-") }
    if words.first == "sudo" || words.first == "time" { words = words.dropFirst() }
    guard let first = words.first else { return nil }
    let tool = CICommandMining.basename(first)
    guard let kinds = CICommandMining.tools[tool] else { return nil }

    var steps: Set<AreaStep> = []
    var directory = cwd
    var names: [String] = []
    var directoryFlag: (index: Int, flag: String, inline: Bool, target: String)?
    var index = words.startIndex
    while index < words.endIndex {
      let word = words[index]
      let next = words.index(after: index) < words.endIndex ? words[words.index(after: index)] : nil
      let (flag, inline) = splitFlag(word)
      if directoryFlags.contains(flag) || (flag == "-C" && tool != "git") {
        guard let value = inline ?? next, let target = CICommandMining.join(cwd, value) else {
          return nil
        }
        directory = flag == "--manifest-path" ? CICommandMining.dirname(target) : target
        directoryFlag = (index, flag, inline != nil, target)
        if inline == nil { index = words.index(after: index) }
      } else if nameFlags.contains(flag) {
        guard let value = inline ?? next else { return nil }
        names.append(value.trimmingCharacters(in: CharacterSet(charactersIn: "'\"")))
        if inline == nil { index = words.index(after: index) }
      } else if valueFlags.contains(flag) {
        if inline == nil { index = words.index(after: index) }
      } else if flag == "--build" {
        steps.insert(.build)
      } else if !word.hasPrefix("-") {
        let lowered = word.lowercased()
        if CICommandMining.setupWords.contains(lowered) { return nil }
        if !lowered.contains("/"), !lowered.contains(".") {
          for part in [lowered] + lowered.split(separator: ":").map(String.init) {
            if let step = CICommandMining.stepWords[part] { steps.insert(step) }
          }
        }
      }
      index = words.index(after: index)
    }
    guard steps.count == 1, let step = steps.first else { return nil }
    var candidate = CICommandMining.Candidate(
      step: step, segment: segment, cwd: cwd, directory: directory, kinds: kinds, names: names,
      source: source)
    if let directoryFlag {
      candidate.retarget = { root in
        retarget(allWords, flag: directoryFlag, root: root)
      }
    }
    return candidate
  }

  /// `words` with the directory flag at `flag.index` rewritten relative to `root`, or removed
  /// when it names `root` itself, which is where the area runner already runs.
  private static func retarget(
    _ words: [String], flag: (index: Int, flag: String, inline: Bool, target: String),
    root: String
  ) -> String? {
    guard CICommandMining.contains(root, flag.target) else { return nil }
    let path = CICommandMining.relative(flag.target, to: root)
    let redundant = flag.flag == "--manifest-path" ? path == "Cargo.toml" : path == "."
    var rewritten = words
    let span = flag.inline ? flag.index...flag.index : flag.index...(flag.index + 1)
    let replacement =
      redundant
      ? []
      : flag.inline
        ? ["\(flag.flag)=\(CICommandMining.quote(path))"]
        : [flag.flag, CICommandMining.quote(path)]
    rewritten.replaceSubrange(span, with: replacement)
    return rewritten.joined(separator: " ")
  }

  static let directoryFlags: Set<String> = [
    "--prefix", "--package-path", "--manifest-path", "--cwd", "--dir", "--working-directory",
    "--project-dir", "--rootdir",
  ]

  /// Flags whose value is a name or a directory, such as `cmake -B build`, never a step word.
  static let valueFlags: Set<String> = [
    "-B", "-S", "-G", "-D", "-e", "-j", "--config", "--target", "--preset", "--only", "-o",
    "--output",
  ]

  static let nameFlags: Set<String> = [
    "-p", "--package", "--filter", "-F", "--workspace", "-w",
  ]

  /// `--flag=value` as its flag and value; any other word as itself with no value.
  private static func splitFlag(_ word: String) -> (String, String?) {
    guard word.hasPrefix("-"), let equals = word.firstIndex(of: "=") else { return (word, nil) }
    return (String(word[..<equals]), String(word[word.index(after: equals)...]))
  }
}

/// The `env:` a workflow step runs with: the workflow's, then its job's, then its own, the
/// narrowest scope winning for each name. A value is carried only when it is a literal, or
/// `${{ env.NAME }}` naming a value already carried; a secret or any other expression is left out
/// and named, so the mined command never holds a secret or a value CI alone knows.
struct WorkflowEnvironment: Equatable {
  struct Variable: Equatable {
    let name: String
    let value: String
  }

  struct LeftOut: Equatable {
    let name: String
    let reason: String
  }

  private(set) var variables: [Variable] = []
  private(set) var leftOut: [LeftOut] = []

  /// This environment with `entries` from a narrower `scope` laid over it; `nil` entries are an
  /// `env:` this can't read, which is named and leaves the wider values in place.
  func narrowed(by entries: [(name: String, value: String)]?, scope: String)
    -> WorkflowEnvironment
  {
    var result = self
    guard let entries else {
      result.leftOut.append(LeftOut(name: "the \(scope) env:", reason: "is written inline"))
      return result
    }
    for (name, raw) in entries {
      result.variables.removeAll { $0.name == name }
      result.leftOut.removeAll { $0.name == name }
      switch resolve(raw, in: self) {
      case .success(let value): result.variables.append(Variable(name: name, value: value))
      case .failure(let reason): result.leftOut.append(LeftOut(name: name, reason: reason.text))
      }
    }
    return result
  }

  private struct Unresolved: Error {
    let text: String
  }

  private func resolve(_ raw: String, in wider: WorkflowEnvironment) -> Result<String, Unresolved> {
    if raw.hasPrefix("|") || raw.hasPrefix(">") {
      return .failure(Unresolved(text: "spans several lines"))
    }
    if raw.contains("secrets.") { return .failure(Unresolved(text: "is a secret")) }
    var value = ""
    var rest = Substring(raw)
    while let open = rest.range(of: "${{") {
      guard let close = rest[open.upperBound...].range(of: "}}") else {
        return .failure(Unresolved(text: "is an expression discover can't resolve"))
      }
      let expression = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
      guard expression.hasPrefix("env."),
        let known = wider.variables.first(where: { $0.name == expression.dropFirst(4) })
      else { return .failure(Unresolved(text: "is an expression discover can't resolve")) }
      value += rest[..<open.lowerBound] + known.value
      rest = rest[close.upperBound...]
    }
    return .success(value + rest)
  }

  /// The source note for what a command left out.
  static func note(_ leftOut: [LeftOut]) -> String {
    "left out CI env: " + leftOut.map { "\($0.name) \($0.reason)" }.joined(separator: ", ")
  }

  /// `value` as 1 shell word that the shell leaves as written.
  static func quote(_ value: String) -> String {
    let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-./:@%+,="))
    if value.unicodeScalars.allSatisfy(plain.contains) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
