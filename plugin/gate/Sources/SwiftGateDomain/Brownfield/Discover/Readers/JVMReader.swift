import Foundation

/// Reads `build.gradle(.kts)` and `pom.xml`: an area per module, the test task with a filter, its linter.
///
/// Gradle: every project a `settings.gradle(.kts)` includes, or the single project of a build with
/// no includes or no settings file. Maven: every `pom.xml` that isn't an aggregator, run from the
/// top of its parent chain with `-pl`. A tracked `gradlew` or `mvnw` is used when present; without
/// one the command names the bare tool, its confidence is `guessed`, and its source says so.
///
/// Every command runs from the module's directory, the area root: a wrapper above it is reached
/// with `../`, Gradle finds its settings file by searching up, and Maven is pointed at the top
/// `pom.xml` with `-f`.
public struct JVMReader: EcosystemReader {
  public init() {}

  public func areas(in tree: TrackedTreeSnapshot) -> [ProposedArea] {
    let paths = tree.paths.filter { !BuildFilePaths.isSkipped($0) }
    let context = JVMContext(tree: tree, listed: Set(tree.paths))
    return gradleAreas(paths, context) + mavenAreas(paths, context)
  }

  // MARK: - Gradle

  private func gradleAreas(_ paths: [String], _ context: JVMContext) -> [ProposedArea] {
    let builds = Self.byDirectory(paths, names: ["build.gradle.kts", "build.gradle"])
    let settings = Self.byDirectory(paths, names: ["settings.gradle.kts", "settings.gradle"])
    var areas: [ProposedArea] = []
    for (directory, settingsPath) in settings.sorted(by: { $0.key < $1.key }) {
      let text = BuildFilePaths.text(context.tree, settingsPath) ?? ""
      let includes = Self.gradleIncludes(text)
      if includes.isEmpty {
        guard let build = builds[directory] else { continue }
        let name = Self.rootProjectName(text) ?? BuildFilePaths.defaultName(directory)
        areas.append(
          gradleArea(
            name: name, root: directory, build: directory, module: nil, buildFile: build,
            context: context, builds: builds))
        continue
      }
      for module in includes {
        let root = BuildFilePaths.join(
          directory, module.split(separator: ":").joined(separator: "/"))
        let name = module.split(separator: ":").last.map(String.init) ?? root
        areas.append(
          gradleArea(
            name: name, root: root, build: directory, module: module,
            buildFile: builds[root] ?? settingsPath, context: context, builds: builds))
      }
    }
    for (directory, build) in builds.sorted(by: { $0.key < $1.key })
    where !BuildFilePaths.ancestors(of: directory).contains(where: { settings[$0] != nil }) {
      areas.append(
        gradleArea(
          name: BuildFilePaths.defaultName(directory), root: directory, build: directory,
          module: nil, buildFile: build, context: context, builds: builds))
    }
    return areas
  }

  /// - Parameters:
  ///   - build: the directory Gradle runs in, holding the settings file and any `gradlew`.
  ///   - module: the project path, such as `:app`; `nil` for a single-project build.
  private func gradleArea(
    name: String, root: String, build: String, module: String?, buildFile: String,
    context: JVMContext, builds: [String: String]
  ) -> ProposedArea {
    let wrapper = context.listed.contains(BuildFilePaths.join(build, "gradlew"))
    let tool =
      wrapper ? Self.fromRoot(root, to: BuildFilePaths.join(build, "gradlew")) : "gradle"
    let text = BuildFilePaths.text(context.tree, buildFile) ?? ""
    let flavor = GradleFlavor(text)
    let command = { (task: String) in
      "\(tool) \(module.map { "\($0):" } ?? "")\(task)"
    }
    let value = { (command: String, source: String, confidence: Confidence) in
      wrapper
        ? Sourced(value: command, source: source, confidence: confidence)
        : Sourced(value: command, source: "\(source) (no Gradle wrapper)", confidence: .guessed)
    }
    var commands: [AreaStep: Sourced<String>] = [
      .test: value(command(flavor.testTask), buildFile, flavor.confidence),
      .build: value(command(flavor.buildTask), buildFile, flavor.confidence),
    ]
    var missing: [AreaStep: String] = [:]
    if flavor.filters {
      commands[.testFiles] = value(
        command("\(flavor.testTask) --tests {tests}"), buildFile, flavor.confidence)
    } else {
      missing[.testFiles] = "a multiplatform test task takes no --tests filter"
    }
    let candidates = [buildFile] + [builds[build]].compactMap { $0 }.filter { $0 != buildFile }
    let lint = Self.firstLinter(
      candidates, context: context,
      linters: [
        ("spotless", "spotlessCheck"), ("ktlint", "ktlintCheck"), ("detekt", "detekt"),
        ("checkstyle", "checkstyleMain"),
      ])
    if let (task, source) = lint {
      commands[.lint] = value(command(task), source, .found)
    } else {
      missing[.lint] = "no linter configured"
    }
    return ProposedArea(
      name: name, root: root, language: context.language(under: root), kind: .jvm,
      source: buildFile, commands: commands, missing: missing, testGlobs: Self.testGlobs(root),
      xcode: nil, generatedProjectTracked: nil)
  }

  /// The project paths `include` lines name, each starting with `:`.
  static func gradleIncludes(_ text: String) -> [String] {
    var modules: [String] = []
    var pending: String?
    for rawLine in text.split(separator: "\n") {
      let line = rawLine.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
      if let open = pending {
        let joined = open + " " + line
        if joined.filter({ $0 == "(" }).count > joined.filter({ $0 == ")" }).count {
          pending = joined
          continue
        }
        modules += BuildFilePaths.quotedStrings(joined[...])
        pending = nil
        continue
      }
      guard line.hasPrefix("include"),
        let next = line.dropFirst("include".count).first, "( '\"".contains(next)
      else { continue }
      if line.filter({ $0 == "(" }).count > line.filter({ $0 == ")" }).count {
        pending = line
      } else {
        modules += BuildFilePaths.quotedStrings(line[...])
      }
    }
    return modules.map { $0.hasPrefix(":") ? $0 : ":" + $0 }
  }

  static func rootProjectName(_ text: String) -> String? {
    text.split(separator: "\n").first {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("rootProject.name")
    }.flatMap { BuildFilePaths.quotedStrings($0).first }
  }

  // MARK: - Maven

  private func mavenAreas(_ paths: [String], _ context: JVMContext) -> [ProposedArea] {
    let poms = Self.byDirectory(paths, names: ["pom.xml"])
    return poms.sorted(by: { $0.key < $1.key }).compactMap { directory, pom -> ProposedArea? in
      let text = BuildFilePaths.text(context.tree, pom) ?? ""
      if text.contains("<module>") { return nil }
      var top = directory
      while top != ".", poms[CICommandMining.dirname(top)] != nil {
        top = CICommandMining.dirname(top)
      }
      let wrapper = context.listed.contains(BuildFilePaths.join(top, "mvnw"))
      let tool = wrapper ? Self.fromRoot(directory, to: BuildFilePaths.join(top, "mvnw")) : "mvn"
      let select =
        top == directory
        ? ""
        : " -f \(CICommandMining.quote(BuildFilePaths.relativeFrom(directory, to: poms[top] ?? "pom.xml")))"
          + " -pl \(CICommandMining.quote(BuildFilePaths.relative(directory, to: top)))"
      let command = { (goal: String) in "\(tool)\(select) \(goal)" }
      let value = { (command: String, source: String) in
        wrapper
          ? Sourced(value: command, source: source, confidence: .found)
          : Sourced(value: command, source: "\(source) (no Maven wrapper)", confidence: .guessed)
      }
      var commands: [AreaStep: Sourced<String>] = [
        .test: value(command("test"), pom),
        .testFiles: value(command("test -Dtest={tests}"), pom),
        .build: value(command("package -DskipTests"), pom),
      ]
      var missing: [AreaStep: String] = [:]
      let candidates = [pom] + [poms[top]].compactMap { $0 }.filter { $0 != pom }
      let lint = Self.firstLinter(
        candidates, context: context,
        linters: [
          ("spotless-maven-plugin", "spotless:check"),
          ("maven-checkstyle-plugin", "checkstyle:check"),
        ])
      if let (goal, source) = lint {
        commands[.lint] = value(command(goal), source)
      } else {
        missing[.lint] = "no linter configured"
      }
      return ProposedArea(
        name: Self.artifactID(text) ?? BuildFilePaths.defaultName(directory), root: directory,
        language: context.language(under: directory), kind: .jvm, source: pom,
        commands: commands, missing: missing, testGlobs: Self.testGlobs(directory), xcode: nil,
        generatedProjectTracked: nil)
    }
  }

  /// The project's own `artifactId`: the first one outside `<parent>`.
  static func artifactID(_ text: String) -> String? {
    var body = Substring(text)
    if let open = body.range(of: "<parent>"), let close = body.range(of: "</parent>"),
      open.lowerBound < close.lowerBound
    {
      body = body[..<open.lowerBound] + body[close.upperBound...]
    }
    guard let open = body.range(of: "<artifactId>"),
      let close = body[open.upperBound...].range(of: "</artifactId>")
    else { return nil }
    let name = body[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
    return name.isEmpty || name.contains("$") ? nil : name
  }

  // MARK: - Shared

  /// The first linter any of `files` mentions, in `linters` order, with the file that named it.
  private static func firstLinter(
    _ files: [String], context: JVMContext, linters: [(marker: String, task: String)]
  ) -> (task: String, source: String)? {
    let texts = files.map { ($0, BuildFilePaths.text(context.tree, $0) ?? "") }
    for (marker, task) in linters {
      if let (file, _) = texts.first(where: { $0.1.contains(marker) }) { return (task, file) }
    }
    return nil
  }

  /// A wrapper script at repository-relative `script`, as run from `root`: `./gradlew` beside
  /// it, `../gradlew` from a module below it.
  private static func fromRoot(_ root: String, to script: String) -> String {
    let path = BuildFilePaths.relativeFrom(root, to: script)
    return CICommandMining.quote(path.hasPrefix("../") ? path : "./" + path)
  }

  private static func byDirectory(_ paths: [String], names: [String]) -> [String: String] {
    var found: [String: String] = [:]
    for name in names {
      for path in paths where CICommandMining.basename(path) == name {
        let directory = CICommandMining.dirname(path)
        if found[directory] == nil { found[directory] = path }
      }
    }
    return found
  }

  private static func testGlobs(_ root: String) -> [String] {
    ["src/test/**/*.java", "src/test/**/*.kt", "src/*Test/**/*.java", "src/*Test/**/*.kt"].map {
      BuildFilePaths.join(root, $0)
    }
  }
}

private struct JVMContext {
  let tree: TrackedTreeSnapshot
  let listed: Set<String>

  /// Kotlin when more tracked sources under `root` are Kotlin than Java.
  func language(under root: String) -> AreaLanguage {
    let prefix = root == "." ? "" : root + "/"
    var kotlin = 0
    var java = 0
    for path in tree.paths where path.hasPrefix(prefix) {
      if path.hasSuffix(".kt") { kotlin += 1 } else if path.hasSuffix(".java") { java += 1 }
    }
    return kotlin > java ? .kotlin : .java
  }
}

/// How a Gradle project names its unit test and build tasks. An Android or multiplatform plugin
/// replaces `test` with per-variant or per-target tasks, so those names are guesses.
private struct GradleFlavor {
  let testTask: String
  let buildTask: String
  /// Whether the test task takes `--tests`.
  let filters: Bool
  let confidence: Confidence

  init(_ buildFile: String) {
    let multiplatform = [
      "kotlin.multiplatform", "kotlin(\"multiplatform\")", "kotlinMultiplatform",
    ]
    if multiplatform.contains(where: { buildFile.contains($0) }) {
      (testTask, buildTask, filters, confidence) = ("allTests", "assemble", false, .guessed)
    } else if ["com.android", "android.application", "android.library"].contains(where: {
      buildFile.contains($0)
    }) {
      (testTask, buildTask, filters, confidence) = (
        "testDebugUnitTest", "assembleDebug", true, .guessed
      )
    } else {
      (testTask, buildTask, filters, confidence) = ("test", "assemble", true, .found)
    }
  }
}
