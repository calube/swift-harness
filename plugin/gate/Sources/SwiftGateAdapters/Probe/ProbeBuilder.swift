import Foundation
import SwiftGateDomain

/// What the scratch package is built for (spec §6.2): the iOS simulator through `xcodebuild`, or
/// the host through `swift build` for a package that declares no iOS platform. The raw value is
/// the SDK name `xcrun --sdk` takes.
public enum ProbePlatform: String, Sendable, Equatable, Codable {
  case iOSSimulator = "iphonesimulator"
  case host = "macosx"
}

/// One remote package the scratch package depends on, pinned to the target's `Package.resolved`.
public struct ProbeDependency: Sendable, Equatable {
  public let identity: String
  public let url: String
  /// The exact version from `Package.resolved`, never the manifest's range.
  public let version: String
  /// Package traits the target enables; empty for the package's defaults.
  public let traits: [String]
  /// The products of this package the target itself depends on.
  public let products: [String]

  public init(identity: String, url: String, version: String, traits: [String], products: [String])
  {
    self.identity = identity
    self.url = url
    self.version = version
    self.traits = traits
    self.products = products
  }
}

/// A deployment target copied from the target package, spelled as `SupportedPlatform` spells it.
public struct ProbePlatformRequirement: Sendable, Equatable {
  public let name: String
  public let version: String

  public init(name: String, version: String) {
    self.name = name
    self.version = version
  }
}

/// Everything about the target package a probe build depends on.
public struct ProbeTarget: Sendable, Equatable {
  public let platform: ProbePlatform
  /// What `xcrun --sdk <platform> --show-sdk-version` reports; recorded as the verdict's `sdk`.
  public let sdkVersion: String
  public let platforms: [ProbePlatformRequirement]
  public let dependencies: [ProbeDependency]
  /// Every versioned pin in the target's `Package.resolved`: identity → version.
  public let pins: [String: String]
  /// The target's `Package.resolved`, copied into the scratch package so transitive packages
  /// resolve to the same versions.
  public let packageResolved: Data?

  public init(
    platform: ProbePlatform, sdkVersion: String, platforms: [ProbePlatformRequirement],
    dependencies: [ProbeDependency], pins: [String: String], packageResolved: Data?
  ) {
    self.platform = platform
    self.sdkVersion = sdkVersion
    self.platforms = platforms
    self.dependencies = dependencies
    self.pins = pins
    self.packageResolved = packageResolved
  }

  /// The reuse cache's SDK bucket (spec §8.6): the platform is part of it because the same
  /// version number names both the macOS and the iOS simulator SDK.
  public var cachePin: String { platform.rawValue + sdkVersion }
}

public enum ProbeError: Error, Sendable, Equatable {
  case process(String)
  case manifest(String)
  case targetNotFound(String)
  /// A remote dependency the target uses has no version in `Package.resolved`.
  case unpinned(identity: String)
  case sdkUnavailable(ProbePlatform)

  public var message: String {
    switch self {
    case .process(let detail): detail
    case .manifest(let detail): "can't read the target package's manifest: \(detail)"
    case .targetNotFound(let name): "the package declares no target named `\(name)`"
    case .unpinned(let identity):
      "`\(identity)` has no version in the target's Package.resolved; resolve the package first"
    case .sdkUnavailable(let platform):
      "`xcrun --sdk \(platform.rawValue) --show-sdk-version` reported no version"
    }
  }
}

/// Reads a target package through `swift package dump-package` (no dependency is fetched) and
/// its `Package.resolved`, and keeps only what a probe may depend on.
public enum ProbeTargetLoader {
  public struct Load: Sendable, Equatable {
    public let target: ProbeTarget
    /// A product left out of the scratch package, and why. Shown to the user, never dropped
    /// silently.
    public let notes: [String]
  }

  /// Issue reporting stays out of a direct dependency before Swift 6.4 (plan toolchain facts);
  /// the package was renamed from `xctest-dynamic-overlay`, so both identities count.
  static let excludedIdentities: Set<String> = ["swift-issue-reporting", "xctest-dynamic-overlay"]

  /// - Parameter sdkVersion: overrides the `xcrun` lookup.
  public static func load(
    packageDirectory: URL, target: String, runner: any ProcessRunner, sdkVersion: String? = nil
  ) async throws(ProbeError) -> Load {
    let dump = try await run(
      "swift", ["package", "dump-package"], in: packageDirectory, runner: runner)
    guard dump.status.isSuccess else {
      throw .manifest("swift package dump-package exited \(dump.status): \(dump.stderr.text)")
    }
    let resolvedURL = packageDirectory.appending(path: "Package.resolved")
    let resolved = try? Data(contentsOf: resolvedURL)
    let parsed = try parse(dumpPackageJSON: dump.stdout.bytes, target: target, resolved: resolved)
    let version: String
    if let sdkVersion {
      version = sdkVersion
    } else {
      version = try await currentSDKVersion(parsed.platform, runner: runner)
    }
    return Load(
      target: ProbeTarget(
        platform: parsed.platform, sdkVersion: version, platforms: parsed.platforms,
        dependencies: parsed.dependencies, pins: parsed.pins, packageResolved: resolved),
      notes: parsed.notes)
  }

  static func currentSDKVersion(_ platform: ProbePlatform, runner: any ProcessRunner)
    async throws(ProbeError) -> String
  {
    let output = try await run(
      "xcrun", ["--sdk", platform.rawValue, "--show-sdk-version"], in: nil, runner: runner)
    let version = output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard output.status.isSuccess, !version.isEmpty else { throw .sdkUnavailable(platform) }
    return version
  }

  private struct Parsed {
    var platform: ProbePlatform
    var platforms: [ProbePlatformRequirement]
    var dependencies: [ProbeDependency]
    var pins: [String: String]
    var notes: [String]
  }

  private static func parse(dumpPackageJSON: Data, target name: String, resolved: Data?)
    throws(ProbeError) -> Parsed
  {
    let dump: DumpPackage
    do {
      dump = try JSONDecoder().decode(DumpPackage.self, from: dumpPackageJSON)
    } catch {
      throw .manifest(String(describing: error))
    }
    guard let target = dump.targets.first(where: { $0.name == name }) else {
      throw .targetNotFound(name)
    }
    var pins: [String: String] = [:]
    if let resolved {
      do {
        pins = try ResolvedPins.parse(resolved)
      } catch {
        throw .manifest(String(describing: error))
      }
    }

    var notes: [String] = []
    var productsByPackage: [String: [String]] = [:]
    for dependency in target.dependencies {
      switch dependency {
      case .product(let product, let package):
        productsByPackage[package.lowercased(), default: []].append(product)
      case .byName(let byName) where !dump.targets.contains(where: { $0.name == byName }):
        notes.append("left out `\(byName)`: a by-name dependency names no package to pin")
      case .byName, .target, .other:
        break
      }
    }

    var dependencies: [ProbeDependency] = []
    for package in dump.dependencies {
      guard let products = productsByPackage[package.identity] else { continue }
      let names = products.map { "`\($0)`" }.joined(separator: ", ")
      guard let url = package.url else {
        notes.append(
          "left out \(names) from local package `\(package.identity)`: codebase code is cited "
            + "by file, not probed")
        continue
      }
      if excludedIdentities.contains(package.identity) {
        notes.append(
          "left out \(names): `\(package.identity)` is never a direct dependency before Swift 6.4")
        continue
      }
      guard let version = pins[package.identity] else {
        throw .unpinned(identity: package.identity)
      }
      dependencies.append(
        ProbeDependency(
          identity: package.identity, url: url, version: version,
          traits: package.traits.filter { $0 != "default" }, products: products))
    }

    let declared = Set(dump.dependencies.map(\.identity))
    for (package, products) in productsByPackage.sorted(by: { $0.key < $1.key })
    where !declared.contains(package) {
      notes.append(
        "left out \(products.map { "`\($0)`" }.joined(separator: ", ")): no declared "
          + "dependency has the identity `\(package)`")
    }

    var platforms: [ProbePlatformRequirement] = []
    for platform in dump.platforms {
      guard let spelling = platformSpellings[platform.platformName] else {
        notes.append("left out the `\(platform.platformName)` deployment target")
        continue
      }
      platforms.append(ProbePlatformRequirement(name: spelling, version: platform.version))
    }
    let isIOS = dump.platforms.contains { $0.platformName == "ios" }
    return Parsed(
      platform: isIOS ? .iOSSimulator : .host, platforms: platforms,
      dependencies: dependencies.sorted { $0.identity < $1.identity }, pins: pins, notes: notes)
  }

  private static let platformSpellings = [
    "ios": "iOS", "macos": "macOS", "tvos": "tvOS", "watchos": "watchOS",
    "visionos": "visionOS", "maccatalyst": "macCatalyst",
  ]

  private static func run(
    _ executable: String, _ arguments: [String], in directory: URL?, runner: any ProcessRunner
  ) async throws(ProbeError) -> ProcessOutput {
    do {
      return try await runner.run(
        ProcessInvocation(
          executable: executable, arguments: arguments, workingDirectory: directory?.path,
          timeout: .seconds(300)))
    } catch {
      throw .process("\(executable) \(arguments.joined(separator: " ")) could not run: \(error)")
    }
  }
}

/// The parts of `swift package dump-package` (Swift 6.2) a probe reads.
private struct DumpPackage: Decodable {
  struct Platform: Decodable {
    let platformName: String
    let version: String
  }

  struct Dependency: Decodable {
    let identity: String
    /// `nil` for a local (`path:`) package.
    let url: String?
    let traits: [String]

    private enum Kind: String, CodingKey { case sourceControl, fileSystem, registry }
    private struct Body: Decodable {
      struct Location: Decodable {
        struct Remote: Decodable { let urlString: String }
        let remote: [Remote]?
      }
      struct Trait: Decodable { let name: String }
      let identity: String
      let location: Location?
      let traits: [Trait]?
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Kind.self)
      guard let kind = container.allKeys.first else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "unknown dependency kind"))
      }
      let body = try container.decode([Body].self, forKey: kind)
      guard let first = body.first else {
        throw DecodingError.dataCorrupted(
          .init(codingPath: decoder.codingPath, debugDescription: "empty dependency"))
      }
      identity = first.identity
      url = kind == .sourceControl ? first.location?.remote?.first?.urlString : nil
      traits = (first.traits ?? []).map(\.name)
    }
  }

  enum TargetDependency: Decodable {
    case product(name: String, package: String)
    case byName(String)
    case target(String)
    case other

    private enum Kind: String, CodingKey { case product, byName, target }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Kind.self)
      if container.contains(.product) {
        var values = try container.nestedUnkeyedContainer(forKey: .product)
        let name = try values.decode(String.self)
        let package = try values.decodeIfPresent(String.self)
        self = package.map { .product(name: name, package: $0) } ?? .byName(name)
      } else if container.contains(.byName) {
        var values = try container.nestedUnkeyedContainer(forKey: .byName)
        self = .byName(try values.decode(String.self))
      } else if container.contains(.target) {
        var values = try container.nestedUnkeyedContainer(forKey: .target)
        self = .target(try values.decode(String.self))
      } else {
        self = .other
      }
    }
  }

  struct Target: Decodable {
    let name: String
    let dependencies: [TargetDependency]
  }

  let platforms: [Platform]
  let dependencies: [Dependency]
  let targets: [Target]

  private enum CodingKeys: String, CodingKey { case platforms, dependencies, targets }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    platforms = try container.decodeIfPresent([Platform].self, forKey: .platforms) ?? []
    dependencies = try container.decode([Dependency].self, forKey: .dependencies)
    targets = try container.decode([Target].self, forKey: .targets)
  }
}

/// The scratch package's `Package.swift`: one library target holding every probe file, depending
/// only on the target's own remote products. Swift 6 language mode and no default-isolation
/// setting, so a probe sees the same isolation a plain package target does.
public enum ProbeScratchManifest {
  public static let packageName = "ProbeScratch"

  public static func render(_ target: ProbeTarget) -> String {
    var lines = [
      "// swift-tools-version: 6.2",
      "import PackageDescription",
      "",
      "let package = Package(",
      "  name: \(quoted(packageName)),",
    ]
    if !target.platforms.isEmpty {
      let platforms = target.platforms.map { ".\($0.name)(\(quoted($0.version)))" }
      lines.append("  platforms: [\(platforms.joined(separator: ", "))],")
    }
    lines.append(
      "  products: [.library(name: \(quoted(packageName)), targets: [\(quoted(packageName))])],")
    lines.append("  dependencies: [")
    for dependency in target.dependencies {
      var entry =
        "    .package(url: \(quoted(dependency.url)), exact: \(quoted(dependency.version))"
      if !dependency.traits.isEmpty {
        entry += ", traits: [\(dependency.traits.map(quoted).joined(separator: ", "))]"
      }
      lines.append(entry + "),")
    }
    lines.append("  ],")
    lines.append("  targets: [")
    lines.append("    .target(")
    lines.append("      name: \(quoted(packageName)),")
    lines.append("      dependencies: [")
    for dependency in target.dependencies {
      for product in dependency.products {
        lines.append(
          "        .product(name: \(quoted(product)), package: \(quoted(dependency.identity))),")
      }
    }
    lines.append("      ]")
    lines.append("    )")
    lines.append("  ],")
    lines.append("  swiftLanguageModes: [.v6]")
    lines.append(")")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func quoted(_ value: String) -> String {
    "\"" + value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
  }
}

/// The generated `Probe_<id>.swift` (spec §6.2): the snippet's members inside `enum Probe_<id>`,
/// with its unindented `import` lines hoisted above the enum, where Swift allows them.
public enum ProbeWrapper {
  public static func source(claimID: String, snippet: String) -> String {
    var imports: [String] = []
    var body: [String] = []
    var lines = snippet.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
    for line in lines {
      if isImport(line) { imports.append(line) } else { body.append(line) }
    }
    while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
    var out = ""
    if !imports.isEmpty { out += imports.joined(separator: "\n") + "\n\n" }
    out += "enum \(ProbeIdentifier.enumName(forClaimID: claimID)) {\n"
    for line in body {
      out += line.trimmingCharacters(in: .whitespaces).isEmpty ? "\n" : "  \(line)\n"
    }
    return out + "}\n"
  }

  private static func isImport(_ line: String) -> Bool {
    guard let first = line.first, !first.isWhitespace else { return false }
    let words = line.split(separator: " ")
    guard let keyword = words.firstIndex(of: "import") else { return false }
    return words[..<keyword].allSatisfy { $0.hasPrefix("@") }
  }
}

/// Where one worktree's scratch package and its DerivedData live: `.harness/probe/`, never the
/// shared global DerivedData (Foundation §4.4).
public struct ProbeScratchLayout: Sendable, Equatable {
  public let root: URL

  public init(worktreeRoot: URL) {
    root = worktreeRoot.appending(path: ".harness/probe", directoryHint: .isDirectory)
  }

  public var package: URL {
    root.appending(path: ProbeScratchManifest.packageName, directoryHint: .isDirectory)
  }
  public var sources: URL {
    package.appending(path: "Sources/\(ProbeScratchManifest.packageName)")
  }
  public var derivedData: URL { root.appending(path: "DerivedData", directoryHint: .isDirectory) }
}

/// One probe's outcome as written to `<slug>.evidence/probes/`.
public struct ProbeResult: Sendable, Equatable {
  public let record: ProbeVerdictRecord
  /// The verdict came from the reuse cache; nothing was compiled for it.
  public let cached: Bool

  public init(record: ProbeVerdictRecord, cached: Bool) {
    self.record = record
    self.cached = cached
  }

  /// Evidence-relative, the `loc` a probe claim cites.
  public var wrapperPath: String {
    "probes/" + ProbeIdentifier.fileName(forClaimID: record.claimId)
  }
  public var verdictPath: String { ProbeVerdictRecord.path(forClaimID: record.claimId) }
}

public enum ProbeOutcome: Sendable, Equatable {
  /// Every probe has a verdict file. `built` is false when the cache answered for all of them.
  case judged(results: [ProbeResult], built: Bool, notes: [String])
  /// No verdict was written: the snippets, the build or the file system couldn't be trusted.
  case blocked(message: String, notes: [String])
}

/// Builds a design's probe snippets in the worktree's scratch package and writes one wrapper and
/// one verdict file per snippet (spec §6.2). Build only: no test action, no simulator boot.
public struct ProbeBuilder: Sendable {
  static let snippetSuffix = ProbeVerdictRecord.snippetSuffix

  private let runner: any ProcessRunner
  private let cache: EvidenceCacheStore
  private let scratch: ProbeScratchLayout
  private let buildTimeout: Duration

  /// A cold iOS build of a macro-heavy package takes minutes; a wedged one is killed well before
  /// a session gives up on it.
  public init(
    runner: any ProcessRunner, cache: EvidenceCacheStore, scratch: ProbeScratchLayout,
    buildTimeout: Duration = .seconds(45 * 60)
  ) {
    self.runner = runner
    self.cache = cache
    self.scratch = scratch
    self.buildTimeout = buildTimeout
  }

  /// - Parameter evidenceRoot: the design's `<slug>.evidence/` directory.
  public func run(evidenceRoot: URL, target: ProbeTarget) async -> ProbeOutcome {
    let probes = evidenceRoot.appending(path: "probes", directoryHint: .isDirectory)
    var notes: [String] = []
    let snippets: [Snippet]
    do {
      snippets = try readSnippets(in: probes)
    } catch {
      return .blocked(message: error.message, notes: notes)
    }
    guard !snippets.isEmpty else {
      return .blocked(message: "no `*\(Self.snippetSuffix)` files under \(probes.path)", notes: [])
    }

    let wrappers = Dictionary(
      uniqueKeysWithValues: snippets.map {
        ($0.id, ProbeWrapper.source(claimID: $0.id, snippet: $0.source))
      })
    let keys = Dictionary(
      uniqueKeysWithValues: snippets.map { ($0.id, Self.cacheKey(snippet: $0.source, target)) })

    let cached = await lookUp(keys: keys, target: target, notes: &notes)
    let misses = snippets.map(\.id).filter { cached[$0] == nil }

    var built: [String: [ProbeVerdictRecord.Diagnostic]] = [:]
    if !misses.isEmpty {
      switch await build(misses, wrappers: wrappers, target: target) {
      case .failure(let failure): return .blocked(message: failure.description, notes: notes)
      case .success(let diagnostics): built = diagnostics
      }
    }

    var results: [ProbeResult] = []
    for snippet in snippets {
      let id = snippet.id
      let diagnostics = cached[id]?.diagnostics ?? built[id] ?? []
      // Binds the verdict to the exact bytes it judged, so evidence check can refuse it once
      // either file changes or when no probe ever wrote it.
      let record = ProbeVerdictRecord(
        claimId: id, verdict: diagnostics.contains { $0.level == .error } ? .fail : .pass,
        diagnostics: diagnostics, pins: target.pins, sdk: target.sdkVersion,
        snippetSha256: CaptureDigest.sha256Hex(snippet.bytes),
        sourceSha256: CaptureDigest.sha256Hex(Data((wrappers[id] ?? "").utf8)))
      results.append(ProbeResult(record: record, cached: cached[id] != nil))
    }

    do {
      for result in results {
        try Self.write(
          Data((wrappers[result.record.claimId] ?? "").utf8),
          to: evidenceRoot.appending(path: result.wrapperPath))
        try Self.write(
          try ProbeVerdictRecord.encode(result.record),
          to: evidenceRoot.appending(path: result.verdictPath))
      }
    } catch {
      return .blocked(message: "can't write probe results: \(error)", notes: notes)
    }

    for result in results {
      if let hit = cached[result.record.claimId] {
        await markReused(hit.claim, notes: &notes)
      } else if let key = keys[result.record.claimId] {
        await remember(result.record, key: key, target: target, notes: &notes)
      }
    }
    return .judged(results: results, built: !misses.isEmpty, notes: notes)
  }

  /// The argv of the one build, in the scratch package.
  public func buildInvocation(for target: ProbeTarget) -> ProcessInvocation {
    switch target.platform {
    case .host:
      return ProcessInvocation(
        executable: "swift", arguments: ["build"], workingDirectory: scratch.package.path,
        timeout: buildTimeout)
    case .iOSSimulator:
      return ProcessInvocation(
        executable: "/usr/bin/xcrun",
        arguments: [
          "xcodebuild", "build", "-quiet", "-scheme", ProbeScratchManifest.packageName,
          "-destination", "generic/platform=iOS Simulator",
          "-derivedDataPath", scratch.derivedData.path,
          // Headless builds otherwise fail on "Macro … must be enabled"; macro packages are
          // pinned, so the trust decision was made at pin time (spec §6.2).
          "-skipMacroValidation",
        ],
        workingDirectory: scratch.package.path, timeout: buildTimeout)
    }
  }

  // MARK: snippets

  private struct ReadError: Error {
    let message: String
  }

  private struct Snippet {
    let id: String
    let bytes: Data
    let source: String
  }

  private func readSnippets(in directory: URL) throws(ReadError) -> [Snippet] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      throw ReadError(message: "can't list \(directory.path): \(error.localizedDescription)")
    }
    var snippets: [Snippet] = []
    for name in names.sorted() where name.hasSuffix(Self.snippetSuffix) {
      let id = String(name.dropLast(Self.snippetSuffix.count))
      guard Self.isProbeID(id) else {
        throw ReadError(
          message: "`\(name)` is not named `ev-<lowercase letters, digits and hyphens>`")
      }
      let bytes: Data
      do {
        bytes = try Data(contentsOf: directory.appending(path: name))
      } catch {
        throw ReadError(message: "can't read `\(name)`: \(error.localizedDescription)")
      }
      guard let source = String(data: bytes, encoding: .utf8) else {
        throw ReadError(message: "can't read `\(name)`: not UTF-8")
      }
      snippets.append(Snippet(id: id, bytes: bytes, source: source))
    }
    return snippets
  }

  /// Only what ``ProbeIdentifier`` can turn into a Swift identifier; the word-count rule of a
  /// committed id is `design-lint`'s to report.
  static func isProbeID(_ id: String) -> Bool {
    let prefix = IdKind.claim.prefix
    guard id.hasPrefix(prefix), id.count > prefix.count else { return false }
    return id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
  }

  // MARK: build

  private func build(
    _ ids: [String], wrappers: [String: String], target: ProbeTarget
  ) async -> Result<[String: [ProbeVerdictRecord.Diagnostic]], ProbeBuildFailure> {
    do {
      try prepareScratch(ids, wrappers: wrappers, target: target)
    } catch {
      return .failure(ProbeBuildFailure("can't prepare the scratch package: \(error)"))
    }
    let output: ProcessOutput
    do {
      output = try await runner.run(buildInvocation(for: target))
    } catch {
      return .failure(ProbeBuildFailure("the probe build could not run: \(error)"))
    }
    let log = output.stdout.text + "\n" + output.stderr.text
    let parsed = CompilerDiagnostics.parse(log)
    var unique: [ProbeDiagnostic] = []
    for diagnostic in parsed where !unique.contains(diagnostic) { unique.append(diagnostic) }
    let attribution = ProbeAttribution.attribute(unique, probes: ids)
    let stray = attribution.unattributed.filter { $0.level == .error }
    if !stray.isEmpty {
      let named = stray.prefix(3).map { "\($0.file):\($0.line): \($0.message)" }
      return .failure(
        ProbeBuildFailure(
          "the build failed outside any probe file: " + named.joined(separator: "; ")))
    }
    if !output.status.isSuccess, attribution.verdict != .red {
      let tail = log.split(separator: "\n").suffix(5).joined(separator: "\n")
      return .failure(
        ProbeBuildFailure("the build exited \(output.status) with no probe error:\n\(tail)"))
    }
    var diagnostics: [String: [ProbeVerdictRecord.Diagnostic]] = [:]
    for verdict in attribution.verdicts {
      diagnostics[verdict.claimID] = verdict.diagnostics.map {
        Self.recorded($0, claimID: verdict.claimID)
      }
    }
    return .success(diagnostics)
  }

  private struct ProbeBuildFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// Rewrites only what changed, so an unchanged manifest or probe keeps the previous build warm,
  /// and removes every file that is not one of this run's probes.
  private func prepareScratch(_ ids: [String], wrappers: [String: String], target: ProbeTarget)
    throws
  {
    let manager = FileManager.default
    try manager.createDirectory(at: scratch.sources, withIntermediateDirectories: true)
    try Self.writeIfChanged(
      Data(ProbeScratchManifest.render(target).utf8),
      to: scratch.package.appending(path: "Package.swift"))
    let resolved = scratch.package.appending(path: "Package.resolved")
    if let data = target.packageResolved {
      try Self.writeIfChanged(data, to: resolved)
    } else if manager.fileExists(atPath: resolved.path) {
      try manager.removeItem(at: resolved)
    }
    let wanted = Set(ids.map(ProbeIdentifier.fileName(forClaimID:)))
    for name in try manager.contentsOfDirectory(atPath: scratch.sources.path)
    where !wanted.contains(name) {
      try manager.removeItem(at: scratch.sources.appending(path: name))
    }
    for id in ids {
      try Self.writeIfChanged(
        Data((wrappers[id] ?? "").utf8),
        to: scratch.sources.appending(path: ProbeIdentifier.fileName(forClaimID: id)))
    }
  }

  /// Diagnostics are recorded against the evidence-relative wrapper, which carries the same line
  /// numbers as the scratch copy, so the record never holds a machine path.
  private static func recorded(_ diagnostic: ProbeDiagnostic, claimID: String)
    -> ProbeVerdictRecord.Diagnostic
  {
    ProbeVerdictRecord.Diagnostic(
      file: "probes/" + ProbeIdentifier.fileName(forClaimID: claimID), line: diagnostic.line,
      column: diagnostic.column, level: diagnostic.level, message: diagnostic.message)
  }

  // MARK: cache

  private struct CacheHit {
    let claim: ReusableClaim
    let diagnostics: [ProbeVerdictRecord.Diagnostic]
  }

  /// The first line of a cached probe claim's text: everything the verdict depends on, so a
  /// different snippet, deployment target, product set, pin or SDK misses.
  static func cacheKey(snippet: String, _ target: ProbeTarget) -> String {
    let platforms = target.platforms.map { "\($0.name)@\($0.version)" }.joined(separator: ",")
    let products = target.dependencies.flatMap { dependency in
      dependency.products.map { "\(dependency.identity)/\($0)" }
        + dependency.traits.map { "\(dependency.identity)+\($0)" }
    }.joined(separator: ",")
    let pins = target.pins.keys.sorted().map { "\($0)@\(target.pins[$0] ?? "")" }
      .joined(separator: ",")
    return "probe snippet sha256:\(CaptureDigest.sha256Hex(Data(snippet.utf8))) sdk "
      + "\(target.cachePin) platforms [\(platforms)] products [\(products)] pins [\(pins)]"
  }

  private func lookUp(keys: [String: String], target: ProbeTarget, notes: inout [String]) async
    -> [String: CacheHit]
  {
    let contents: EvidenceCacheContents
    do {
      contents = try cache.contents(of: .sdk(pin: target.cachePin))
    } catch {
      notes.append("the probe cache could not be read, so every probe is built: \(error)")
      return [:]
    }
    notes += contents.findings.map(\.message)
    var hits: [String: CacheHit] = [:]
    for (id, key) in keys {
      guard
        let entry = contents.claims.first(where: {
          $0.origin == .probe && $0.claim.kind == .probe
            && $0.claim.claim.text.split(separator: "\n").first.map(String.init) == key
        })
      else { continue }
      let lines = entry.claim.claim.text.split(separator: "\n").dropFirst().joined(separator: "\n")
      let diagnostics = CompilerDiagnostics.parse(lines).map { Self.recorded($0, claimID: id) }
      hits[id] = CacheHit(claim: entry.claim, diagnostics: diagnostics)
    }
    return hits
  }

  /// A cached probe is a claim in the SDK bucket whose text is the key, then the verdict's
  /// diagnostics in compiler form, and whose status is the verdict.
  private func remember(
    _ record: ProbeVerdictRecord, key: String, target: ProbeTarget, notes: inout [String]
  ) async {
    let fileName = ProbeIdentifier.fileName(forClaimID: record.claimId)
    let diagnostics = record.diagnostics.map {
      "\(fileName):\($0.line):\($0.column): \($0.level.rawValue): \($0.message)"
    }
    let claim = Claim(
      id: record.claimId, lane: "probe", text: ([key] + diagnostics).joined(separator: "\n"),
      citation: Citation(kind: .probe, loc: "probes/" + fileName, pin: target.cachePin),
      status: record.verdict == .pass ? .supported : .refuted)
    do {
      try await cache.record(try ReusableClaim(claim), origin: .probe)
    } catch {
      notes.append("\(record.claimId): the verdict was not cached: \(error)")
    }
  }

  private func markReused(_ claim: ReusableClaim, notes: inout [String]) async {
    do {
      try await cache.markReused(claim)
    } catch {
      notes.append("\(claim.claim.id): the cache reuse was not recorded: \(error)")
    }
  }

  // MARK: files

  private static func write(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private static func writeIfChanged(_ data: Data, to url: URL) throws {
    if (try? Data(contentsOf: url)) == data { return }
    try write(data, to: url)
  }
}
