import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateRules

/// Checker hygiene (spec §10): every rule has seeded fixtures, every `bad` fixture trips its rule,
/// every `good` fixture and the sample app pass. Each failure is one finding; any failure is RED.
enum SelfTest {
  static let ruleID = "swiftgate.self-test"
  static let rulesDirectory = "gate/Fixtures/rules"
  static let archDirectory = "gate/Fixtures/arch"
  /// Relative to the checkout: the sample app sits beside the plugin, not in it.
  static let sampleDirectory = "examples/SampleApp"
  static let seedsDirectory = "gate/Fixtures/seeds"

  private struct Failure: Sendable {
    let file: String
    let message: String
  }

  private enum Part: Sendable {
    case failures([Failure])
    /// The environment stopped a check (SwiftPM, file system); the self-test proves nothing.
    case blocked(String)
  }

  /// - Parameter sampleApp: the clean sample app; `nil` finds it under the git checkout that
  ///   holds `harnessRoot`, or under `harnessRoot` when no checkout holds it.
  static func run(harnessRoot: URL, sampleApp: URL? = nil) async -> StaticCheckOutcome {
    let sampleApp = sampleApp ?? defaultSampleApp(harnessRoot: harnessRoot)
    let parts = await withTaskGroup(of: Part.self) { group in
      group.addTask { ruleFixtures(harnessRoot: harnessRoot) }
      group.addTask { await archFixtures(harnessRoot: harnessRoot) }
      group.addTask { await Self.sampleApp(sampleApp, harnessRoot: harnessRoot) }
      group.addTask { await seedFixtures(harnessRoot: harnessRoot) }
      var collected: [Part] = []
      for await part in group { collected.append(part) }
      return collected
    }
    var failures: [Failure] = []
    for part in parts {
      switch part {
      case .blocked(let reason): return .blocked(reason: "self-test: \(reason)")
      case .failures(let found): failures += found
      }
    }
    do {
      let findings = try failures.sorted { ($0.file, $0.message) < ($1.file, $1.message) }.map {
        failure throws(ReportContractViolation) in
        try Finding(
          ruleID: ruleID, severity: .major, file: failure.file, line: nil,
          message: failure.message, failureScenario: nil)
      }
      return .checked(RuleRunResult(findings: findings, allowances: []))
    } catch {
      return .blocked(reason: "self-test: \(error)")
    }
  }

  // MARK: - Single-file rule fixtures

  private static func ruleFixtures(harnessRoot: URL) -> Part {
    let root = harnessRoot.appending(path: rulesDirectory, directoryHint: .isDirectory)
    var failures = hygiene(
      directory: rulesDirectory, present: subdirectories(of: root),
      expected: RuleCatalog.all.map(\.descriptor.id))
    for rule in RuleCatalog.all {
      let id = rule.descriptor.id
      let ruleRoot = root.appending(path: id, directoryHint: .isDirectory)
      guard FileManager.default.fileExists(atPath: ruleRoot.path) else { continue }
      let manifest: RuleFixtureManifest
      do {
        let file = ruleRoot.appending(path: "fixture.json")
        manifest =
          FileManager.default.fileExists(atPath: file.path)
          ? try JSONDecoder().decode(RuleFixtureManifest.self, from: Data(contentsOf: file))
          : RuleFixtureManifest()
      } catch {
        failures.append(
          Failure(file: "\(rulesDirectory)/\(id)/fixture.json", message: "unreadable: \(error)"))
        continue
      }
      for variant in ["bad", "good"] {
        let relative = "\(rulesDirectory)/\(id)/\(variant)"
        let files = swiftFiles(in: ruleRoot.appending(path: variant, directoryHint: .isDirectory))
        guard !files.isEmpty else {
          failures.append(Failure(file: relative, message: "no \(variant) fixtures for \(id)"))
          continue
        }
        let results: [RuleFixtureCheck.FileResult]
        do {
          results = try RuleFixtureCheck.run(rule: rule, manifest: manifest, files: files)
        } catch {
          failures.append(Failure(file: relative, message: "could not check: \(error)"))
          continue
        }
        for result in results {
          let file = "\(relative)/\(result.fileName)"
          if variant == "bad", result.findings.isEmpty {
            failures.append(Failure(file: file, message: "\(id) did not fire"))
          } else if variant == "good", let first = result.findings.first {
            failures.append(
              Failure(
                file: file,
                message:
                  "\(id) fired on a good fixture at line \(first.line ?? 0): \(first.message)"))
          }
        }
      }
    }
    return .failures(failures)
  }

  // MARK: - Package-tree arch fixtures

  private static func archFixtures(harnessRoot: URL) async -> Part {
    let root = harnessRoot.appending(path: archDirectory, directoryHint: .isDirectory)
    let expected = ArchCheck.ruleIDs
    var failures = hygiene(
      directory: archDirectory, present: subdirectories(of: root), expected: expected)
    let trees = expected.flatMap { id in ["bad", "good"].map { (id, $0) } }.filter { id, variant in
      FileManager.default.fileExists(atPath: root.appending(path: "\(id)/\(variant)").path)
    }
    let parts = await withTaskGroup(of: Part.self) { group in
      for (id, variant) in trees {
        group.addTask {
          let tree = root.appending(path: "\(id)/\(variant)", directoryHint: .isDirectory)
          let outcome = await ArchCheck.run(
            root: tree, swiftPM: ScopeResolution.liveSwiftPM(root: tree))
          return judgeArch(
            outcome, ruleID: id, variant: variant, file: "\(archDirectory)/\(id)/\(variant)")
        }
      }
      var collected: [Part] = []
      for await part in group { collected.append(part) }
      return collected
    }
    for part in parts {
      switch part {
      case .blocked: return part
      case .failures(let found): failures += found
      }
    }
    return .failures(failures)
  }

  private static func judgeArch(
    _ outcome: StaticCheckOutcome, ruleID: String, variant: String, file: String
  ) -> Part {
    switch outcome {
    case .blocked(let reason): return .blocked("\(file): \(reason)")
    case .invalid(let reason, _):
      return .failures([Failure(file: file, message: "invalid fixture: \(reason)")])
    case .checked(let result):
      let gating = result.findings.filter(\.severity.failsGate)
      let fired = Set(gating.map(\.ruleID))
      if variant == "bad", fired != [ruleID] {
        return .failures([
          Failure(
            file: file,
            message:
              "expected RED from \(ruleID) only, got [\(fired.sorted().joined(separator: ", "))]")
        ])
      }
      if variant == "good", let first = gating.first {
        return .failures([
          Failure(file: file, message: "expected GREEN, got \(first.ruleID): \(first.message)")
        ])
      }
      return .failures([])
    }
  }

  // MARK: - Sample app

  private static func sampleApp(_ root: URL, harnessRoot: URL) async -> Part {
    let label = displayPath(root, under: harnessRoot)
    guard
      FileManager.default.fileExists(atPath: root.appending(path: ConfigLoader.fileName).path)
    else {
      return .failures([
        Failure(
          file: label,
          message: "no \(ConfigLoader.fileName); the clean sample must be gated and GREEN")
      ])
    }
    let swiftPM = ScopeResolution.liveSwiftPM(root: root)
    let checks: [(String, StaticCheckOutcome)] = [
      ("lint", await LintCheck.run(root: root, paths: [], swiftPM: swiftPM)),
      ("testlint", await TestlintCheck.run(root: root, paths: [], swiftPM: swiftPM)),
      ("arch", await ArchCheck.run(root: root, swiftPM: swiftPM)),
    ]
    var failures: [Failure] = []
    for (name, outcome) in checks {
      switch outcome {
      case .blocked(let reason): return .blocked("\(label) \(name): \(reason)")
      case .invalid(let reason, let file):
        failures.append(
          Failure(file: "\(label)/\(file)", message: "\(name): invalid: \(reason)"))
      case .checked(let result):
        for finding in result.findings where finding.severity.failsGate {
          failures.append(
            Failure(
              file: "\(label)/\(finding.file)",
              message: "\(name): \(finding.ruleID) at line \(finding.line ?? 0): \(finding.message)"
            ))
        }
      }
    }
    return .failures(failures)
  }

  /// The checkout is the nearest directory at or above `harnessRoot` with a `.git` entry (a
  /// directory, or the file a linked worktree has).
  static func defaultSampleApp(harnessRoot: URL) -> URL {
    var directory = harnessRoot.standardizedFileURL
    while directory.path != "/" {
      if FileManager.default.fileExists(atPath: directory.appending(path: ".git").path) {
        return directory.appending(path: sampleDirectory, directoryHint: .isDirectory)
      }
      directory = directory.deletingLastPathComponent()
    }
    return harnessRoot.appending(path: sampleDirectory, directoryHint: .isDirectory)
  }

  /// A path under the harness root reads relative to it; anything else stays absolute.
  private static func displayPath(_ url: URL, under root: URL) -> String {
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
  }

  // MARK: - Mechanical seed fixtures (spec §12)

  /// A generic runner over `gate/Fixtures/seeds/<command>/<case>/expected.json`: the case
  /// directory is the input, `expected.json` is the closed, versioned answer key, and adding a
  /// case is the only thing a later wave needs to do — the family that reads it is registered
  /// once, here, per command.
  private static func seedFixtures(harnessRoot: URL) async -> Part {
    let root = harnessRoot.appending(path: seedsDirectory, directoryHint: .isDirectory)
    var failures: [Failure] = []
    for commandName in subdirectories(of: root).sorted() {
      let commandRoot = root.appending(path: commandName, directoryHint: .isDirectory)
      let commandFile = "\(seedsDirectory)/\(commandName)"
      guard let family = SeedFamily(rawValue: commandName) else {
        failures.append(
          Failure(
            file: commandFile,
            message: "no self-test runner is registered for the seed command \"\(commandName)\""))
        continue
      }
      let cases = subdirectories(of: commandRoot)
      guard !cases.isEmpty else {
        failures.append(Failure(file: commandFile, message: "no seed cases"))
        continue
      }
      for caseName in cases.sorted() {
        let caseRoot = commandRoot.appending(path: caseName, directoryHint: .isDirectory)
        let file = "\(commandFile)/\(caseName)"
        guard
          let data = FileManager.default.contents(
            atPath: caseRoot.appending(path: "expected.json").path)
        else {
          failures.append(Failure(file: file, message: "no expected.json"))
          continue
        }
        let expectation: SeedExpectation
        do {
          expectation = try SeedExpectation.decode(data)
        } catch {
          failures.append(Failure(file: "\(file)/expected.json", message: "\(error)"))
          continue
        }
        switch await family.run(caseDirectory: caseRoot, harnessRoot: harnessRoot) {
        case .blocked(let reason):
          failures.append(Failure(file: file, message: "blocked: \(reason)"))
        case .ruleIDs(let actualSet):
          let actual = actualSet.sorted()
          if actual != expectation.ruleIDs {
            failures.append(
              Failure(
                file: file,
                message:
                  "expected rule id(s) [\(expectation.ruleIDs.joined(separator: ", "))], "
                  + "got [\(actual.joined(separator: ", "))]"))
          }
        }
      }
    }
    return .failures(failures)
  }

  // MARK: - Helpers

  private static func hygiene(directory: String, present: Set<String>, expected: [String])
    -> [Failure]
  {
    let expectedSet = Set(expected)
    return expectedSet.subtracting(present).sorted().map {
      Failure(file: "\(directory)/\($0)", message: "rule \($0) has no fixture")
    }
      + present.subtracting(expectedSet).sorted().map {
        Failure(file: "\(directory)/\($0)", message: "fixture for unknown rule \($0)")
      }
  }

  private static func subdirectories(of directory: URL) -> Set<String> {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles))
      ?? []
    return Set(
      entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        .map(\.lastPathComponent))
  }

  private static func swiftFiles(in directory: URL) -> [(name: String, text: String)] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return entries.filter { $0.pathExtension == "swift" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) }
      }
  }
}

/// `gate/Fixtures/seeds/<command>/<case>/expected.json`'s closed schema: unknown keys, an
/// unsupported `schemaVersion`, a malformed `verdict`, or `ruleIDs` that disagree with `verdict`
/// (non-empty only when red, never containing a duplicate, and sorted so two authors don't fight
/// over key order) each name themselves rather than decode into a guess.
private struct SeedExpectation: Sendable, Equatable {
  enum Verdict: String { case red, green }

  let verdict: Verdict
  let ruleIDs: [String]

  enum DecodeError: Error, CustomStringConvertible, Sendable, Equatable {
    case notAnObject
    case unknownKeys([String])
    case badSchemaVersion
    case badVerdict
    case badRuleIDs

    var description: String {
      switch self {
      case .notAnObject: "expected.json must be a JSON object"
      case .unknownKeys(let keys):
        "unknown key(s) in expected.json: \(keys.joined(separator: ", "))"
      case .badSchemaVersion: "expected.json's schemaVersion must be 1"
      case .badVerdict: "expected.json's verdict must be \"red\" or \"green\""
      case .badRuleIDs:
        "expected.json's ruleIDs must be a sorted array of unique, non-empty strings, empty "
          + "iff verdict is green"
      }
    }
  }

  static func decode(_ data: Data) throws(DecodeError) -> SeedExpectation {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let dict = object as? [String: Any]
    else { throw .notAnObject }
    let allowedKeys: Set<String> = ["schemaVersion", "verdict", "ruleIDs"]
    let unknown = Set(dict.keys).subtracting(allowedKeys)
    guard unknown.isEmpty else { throw .unknownKeys(unknown.sorted()) }
    guard let schemaVersion = dict["schemaVersion"] as? Int, schemaVersion == 1 else {
      throw .badSchemaVersion
    }
    guard let verdictRaw = dict["verdict"] as? String, let verdict = Verdict(rawValue: verdictRaw)
    else { throw .badVerdict }
    guard let ruleIDsRaw = dict["ruleIDs"] as? [Any], let ruleIDs = ruleIDsRaw as? [String],
      Set(ruleIDs).count == ruleIDs.count, ruleIDs == ruleIDs.sorted(),
      !ruleIDs.contains(where: \.isEmpty), ruleIDs.isEmpty == (verdict == .green)
    else { throw .badRuleIDs }
    return SeedExpectation(verdict: verdict, ruleIDs: ruleIDs)
  }
}

/// What running a seed case actually produced: the rule-id-shaped identifiers it fired (empty for
/// clean), or an environment failure that proves nothing about the rule itself.
private enum SeedRunOutcome {
  case ruleIDs(Set<String>)
  case blocked(String)
}

/// One command family a seed case can target. Registering a new family is the only
/// `SelfTestCommand` edit a future mechanical-gate command ever needs; every seed under it after
/// that is data, added under `gate/Fixtures/seeds/<command>/`.
private enum SeedFamily: String, Sendable {
  case evidenceCheck = "evidence-check"
  case probe
  case designLint = "design-lint"
  case designDiff = "design-diff"
  case planLint = "plan-lint"
  case docsLint = "docs-lint"
  case prose
  case comments
  case testlint

  func run(caseDirectory: URL, harnessRoot: URL) async -> SeedRunOutcome {
    switch self {
    case .evidenceCheck: await SeedRunners.evidenceCheck(caseDirectory: caseDirectory)
    case .probe: await SeedRunners.probe(caseDirectory: caseDirectory, harnessRoot: harnessRoot)
    case .designLint: await SeedRunners.designLint(caseDirectory: caseDirectory)
    case .designDiff: await SeedRunners.designDiff(caseDirectory: caseDirectory)
    case .planLint:
      await SeedRunners.planLint(caseDirectory: caseDirectory, harnessRoot: harnessRoot)
    case .docsLint: await SeedRunners.docsLint(caseDirectory: caseDirectory)
    case .prose: await SeedRunners.prose(caseDirectory: caseDirectory)
    case .comments: await SeedRunners.comments(caseDirectory: caseDirectory)
    case .testlint: await SeedRunners.testlint(caseDirectory: caseDirectory)
    }
  }
}

/// A throwaway git repository under the system temp directory, for a seed whose command needs
/// real git plumbing (a common dir, `diff --cached`, `ls-files`) — never this checkout's, which
/// every sibling worktree shares.
private struct SeedRepo {
  let root: URL
  let runner: LiveProcessRunner

  static func make(label: String) -> SeedRepo {
    // `CanonicalPath`, never `resolvingSymlinksInPath()`: `swift package describe` reports
    // `realpath(3)`-style paths (`/private/var/...`), and Foundation's own resolver maps those
    // right back to `/var/...`, which would make every reported path read as outside the repo.
    let root = CanonicalPath.url(
      FileManager.default.temporaryDirectory.appending(
        path: "swiftgate-self-test-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory))
    let environment: [String: String] = [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": root.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "swiftgate-self-test", "GIT_AUTHOR_EMAIL": "self-test@example.com",
      "GIT_COMMITTER_NAME": "swiftgate-self-test", "GIT_COMMITTER_EMAIL": "self-test@example.com",
    ]
    return SeedRepo(root: root, runner: LiveProcessRunner(baseEnvironment: environment))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }

  @discardableResult
  func git(_ arguments: String...) async -> Bool {
    (try? await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: root.path,
        timeout: .seconds(30))))?.status.isSuccess ?? false
  }

  /// Writes `relative` under the repo root, creating intermediate directories.
  func write(_ relative: String, _ content: String) -> Bool {
    let url = root.appending(path: relative)
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: url)
      return true
    } catch { return false }
  }

  var git2: LiveGit { LiveGit(runner: runner, repositoryRoot: root.path) }
  var swiftPM: LiveSwiftPM { LiveSwiftPM(runner: runner, repositoryRoot: root.path) }

  /// Writes a one-task `ledger.json` naming `id` under this repo's own common dir, the way
  /// `plan claim`/the orchestrator would — never this checkout's shared plan state — so
  /// `KnownIdSources` (spec §5.1) picks it up as a known ledger task id.
  func seedKnownID(_ id: String, slug: String) async -> Bool {
    do {
      let common = try await git2.commonDirectory()
      let plan = try PlanStateLayout(commonDirectory: common).plan(slug)
      try FileManager.default.createDirectory(
        atPath: plan.directory, withIntermediateDirectories: true)
      let ledger = Ledger(
        schemaVersion: 1, resume: "self-test", maxParallel: 1,
        tasks: [
          LedgerTask(
            id: id, deps: [], writeSet: [], gate: .fast, tests: [], covers: [], estLines: 40,
            status: .pending, worktree: "../\(slug)")
        ], waves: [[id]])
      try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
      return true
    } catch { return false }
  }
}

/// Each family calls the same run-layer code its own command uses — never a re-implementation —
/// and turns the result into the rule-id-shaped identifiers `expected.json` names.
private enum SeedRunners {
  // MARK: evidence check

  static func evidenceCheck(caseDirectory: URL) async -> SeedRunOutcome {
    let design = "docs/example/designs/seed.md"
    let outcome = await EvidenceCheckRun.run(
      options: .init(
        design: design, at: nil, packageResolved: "Package.resolved", sdk: "self-test"),
      root: caseDirectory, runner: LiveProcessRunner())
    switch outcome {
    case .blocked(let message): return .blocked(message)
    case .checked(_, let results):
      let ids: [String] = results.compactMap { result in
        switch result.outcome {
        case .passed, .relocated: return nil
        case .stale: return "evidence-check.stale"
        case .failed(let failure): return "evidence-check.\(failureName(failure))"
        }
      }
      return .ruleIDs(Set(ids))
    }
  }

  /// A closed, hand-named label per `EvidenceCheckFailure` case (never `String(describing:)`,
  /// which would leak an associated value's exact wording into the seed's answer key).
  private static func failureName(_ failure: EvidenceCheckFailure) -> String {
    switch failure {
    case .locPath: "locPath"
    case .locMalformed: "locMalformed"
    case .quoteMissing: "quoteMissing"
    case .quoteNotFound: "quoteNotFound"
    case .citedFileMissing: "citedFileMissing"
    case .lineRangeOutOfBounds: "lineRangeOutOfBounds"
    case .pinMissing: "pinMissing"
    case .pinMalformed: "pinMalformed"
    case .pinPackageMismatch: "pinPackageMismatch"
    case .packageResolvedMissing: "packageResolvedMissing"
    case .packageResolvedMalformed: "packageResolvedMalformed"
    case .packageNotResolved: "packageNotResolved"
    case .pinVersionMismatch: "pinVersionMismatch"
    case .storedFileMissing: "storedFileMissing"
    case .captureNameMismatch: "captureNameMismatch"
    case .captureHashMismatch: "captureHashMismatch"
    case .sdkVersionUnavailable: "sdkVersionUnavailable"
    case .probeVerdictMissing: "probeVerdictMissing"
    case .probeVerdictMalformed: "probeVerdictMalformed"
    case .probeVerdictForOtherClaim: "probeVerdictForOtherClaim"
    case .probeFailed: "probeFailed"
    case .answersFileMissing: "answersFileMissing"
    case .answersFileMalformed: "answersFileMalformed"
    case .answerNotFound: "answerNotFound"
    case .answerQuestionMismatch: "answerQuestionMismatch"
    case .duplicateClaimID: "duplicateClaimID"
    case .probeVerdictUnbound: "probeVerdictUnbound"
    case .probeSourceMissing: "probeSourceMissing"
    case .probeSourceMismatch: "probeSourceMismatch"
    }
  }

  // MARK: probe

  static func probe(caseDirectory: URL, harnessRoot: URL) async -> SeedRunOutcome {
    let snippetsDirectory = caseDirectory.appending(path: "probes", directoryHint: .isDirectory)
    let snippetNames =
      (try? FileManager.default.contentsOfDirectory(atPath: snippetsDirectory.path)) ?? []
    guard !snippetNames.isEmpty else {
      return .blocked("no probes/*.snippet.swift in this case")
    }
    let design = "docs/designs/probe-seed.md"
    let tempRoot = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-self-test-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let probesDestination = tempRoot.appending(
      path: EvidenceLayout(designDocPath: design).probesDirectory, directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(
        at: probesDestination, withIntermediateDirectories: true)
      for name in snippetNames {
        try FileManager.default.copyItem(
          at: snippetsDirectory.appending(path: name), to: probesDestination.appending(path: name))
      }
    } catch {
      return .blocked("could not stage probe snippets: \(error)")
    }
    let package = harnessRoot.appending(
      path: "gate/Fixtures/probe/HostTarget", directoryHint: .isDirectory)
    let report = await ProbeCommandRun.run(
      options: .init(
        design: design, package: package.path, target: "HostTarget", sdk: nil,
        cacheHome: tempRoot.appending(path: "home", directoryHint: .isDirectory)),
      root: tempRoot, runner: LiveProcessRunner())
    if report.verdict == .blocked { return .blocked(report.message) }
    return .ruleIDs(Set(report.probes.filter { $0.verdict == .fail }.map(\.claimId)))
  }

  // MARK: design-lint

  static func designLint(caseDirectory: URL) async -> SeedRunOutcome {
    let docPath = "design.md"
    guard FileManager.default.fileExists(atPath: caseDirectory.appending(path: docPath).path) else {
      return .blocked("no design.md in this case")
    }
    let git = LiveGit(runner: LiveProcessRunner(), repositoryRoot: caseDirectory.path)
    let outcome = await DesignLintCheck.run(
      root: caseDirectory, docPath: docPath, git: git, processRunner: LiveProcessRunner())
    switch outcome {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, _): return .blocked("invalid: \(reason)")
    case .checked(let result):
      return .ruleIDs(Set(result.findings.filter(\.severity.failsGate).map(\.ruleID)))
    }
  }

  // MARK: design-diff

  /// Builds a throwaway git repo from `revisions/1.md` and `revisions/2.md`, commits each in
  /// order, and asks `design-diff --chain` to verify a `plan.json` whose `clarifyChain` claims the
  /// edit was a clarify — `DesignSha.of` computes every sha in that file at run time, never
  /// hand-copied, so the fixture can't drift from what the doc actually hashes to.
  static func designDiff(caseDirectory: URL) async -> SeedRunOutcome {
    let revisions = caseDirectory.appending(path: "revisions", directoryHint: .isDirectory)
    guard
      let first = try? String(
        contentsOf: revisions.appending(path: "1.md"), encoding: .utf8),
      let second = try? String(
        contentsOf: revisions.appending(path: "2.md"), encoding: .utf8)
    else { return .blocked("revisions/1.md and revisions/2.md are both required") }

    let design = "docs/example/designs/seed.md"
    let tempRoot = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-self-test-design-diff-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: tempRoot) }
    let environment: [String: String] = [
      "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin", "HOME": tempRoot.path,
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_AUTHOR_NAME": "swiftgate-self-test", "GIT_AUTHOR_EMAIL": "self-test@example.com",
      "GIT_COMMITTER_NAME": "swiftgate-self-test", "GIT_COMMITTER_EMAIL": "self-test@example.com",
    ]
    let runner = LiveProcessRunner(baseEnvironment: environment)

    @discardableResult
    func git(_ arguments: String...) async -> Bool {
      (try? await runner.run(
        ProcessInvocation(
          executable: "git", arguments: arguments, workingDirectory: tempRoot.path,
          timeout: .seconds(30))))?.status.isSuccess ?? false
    }

    do {
      try FileManager.default.createDirectory(
        at: tempRoot.appending(path: "docs/example/designs", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    } catch {
      return .blocked("could not create a temp repo: \(error)")
    }
    guard await git("init", "-q", "-b", "main"), await git("config", "commit.gpgsign", "false")
    else { return .blocked("could not init a temp git repo") }
    let designURL = tempRoot.appending(path: design)
    for (index, text) in [first, second].enumerated() {
      do {
        try text.write(to: designURL, atomically: true, encoding: .utf8)
      } catch {
        return .blocked("could not write revision \(index + 1): \(error)")
      }
      guard await git("add", "-A"), await git("commit", "-q", "-m", "revision \(index + 1)") else {
        return .blocked("could not commit revision \(index + 1)")
      }
    }

    let firstSha = DesignSha.of(first)
    let secondSha = DesignSha.of(second)
    let plan = PlanFile(
      schemaVersion: 1, slug: "self-test-design-diff", design: design, designSha: secondSha,
      approval: .init(decision: .approve, designSha: firstSha, at: Date(timeIntervalSince1970: 0)),
      clarifyChain: [
        .init(fromSha: firstSha, toSha: secondSha, at: Date(timeIntervalSince1970: 0))
      ],
      tier: nil, resume: "self-test")
    do {
      try PlanFileJSON.encode(plan).write(to: tempRoot.appending(path: "plan.json"))
    } catch {
      return .blocked("could not write plan.json: \(error)")
    }

    let git2 = LiveGit(runner: runner, repositoryRoot: tempRoot.path)
    let report = await DesignDiffRun.chain(
      planPath: "plan.json", workingDirectory: tempRoot, git: git2)
    switch report.status {
    case .valid: return .ruleIDs([])
    case .broken:
      guard let problem = report.brokenLink?.problem else {
        return .blocked("broken chain with no brokenLink")
      }
      return .ruleIDs(["design-diff.\(problem.rawValue)"])
    default:
      return .blocked(report.message)
    }
  }

  // MARK: plan-lint

  /// A package with one library module, real enough for `swift package describe` to answer —
  /// every case shares it, so `PlanLintRun.run`'s module graph always resolves the same way and
  /// only the case's own `design.md`/`ledger.json` decide which rule fires.
  private static let planLintPackageManifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
      name: "Sample",
      targets: [
        .target(name: "Core", path: "Sources/Core")
      ]
    )

    """

  private static let planLintConfig = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Sample"
    packages = ["Sample"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    """

  /// `design.md` and `ledger.json` (hand-authored plan-state data, never captured tool output) plus
  /// an optional `bounds.toml` fragment appended under `[plan]`, staged into a throwaway repo with
  /// the shared package above and a `plan.json`/`ledger.json` written where `plan claim` would —
  /// under the repo's own common dir, resolved through real git — then handed to `plan-lint`'s own
  /// run function, never a re-implementation of its checks. An optional `amended.md` is committed
  /// over the design after the plan is made from `design.md`, so a case can move the design on.
  /// Worker packs take their standards from `harnessRoot`, as they do in a consumer repository.
  static func planLint(caseDirectory: URL, harnessRoot: URL) async -> SeedRunOutcome {
    guard
      let design = try? String(
        contentsOf: caseDirectory.appending(path: "design.md"), encoding: .utf8),
      let ledgerData = FileManager.default.contents(
        atPath: caseDirectory.appending(path: "ledger.json").path)
    else { return .blocked("design.md and ledger.json are both required") }
    let ledger: Ledger
    do {
      ledger = try LedgerJSON.decode(ledgerData)
    } catch {
      return .blocked("ledger.json: \(error)")
    }
    let bounds =
      (try? String(contentsOf: caseDirectory.appending(path: "bounds.toml"), encoding: .utf8))
      ?? ""

    let designPath = "docs/example/designs/seed.md"
    let slug = "self-test-plan-lint"
    let repo = SeedRepo.make(label: "plan-lint")
    defer { repo.remove() }

    guard
      repo.write(ConfigLoader.fileName, planLintConfig + bounds),
      repo.write("Sample/Package.swift", planLintPackageManifest),
      repo.write("Sample/Sources/Core/Core.swift", "public enum Core {}\n"),
      repo.write(designPath, design),
      await repo.git("init", "-q", "-b", "main"),
      await repo.git("config", "commit.gpgsign", "false"),
      await repo.git("add", "-A"), await repo.git("commit", "-q", "-m", "seed")
    else { return .blocked("could not build the temp repo") }

    do {
      let commonDirectory = try await repo.git2.commonDirectory()
      let layout = try PlanStateLayout(commonDirectory: commonDirectory)
      let plan = try layout.plan(slug)
      try FileManager.default.createDirectory(
        atPath: plan.directory, withIntermediateDirectories: true)
      let designSha = DesignSha.of(design)
      let file = PlanFile(
        schemaVersion: 1, slug: slug, design: designPath, designSha: designSha,
        approval: .init(
          decision: .approve, designSha: designSha, at: Date(timeIntervalSince1970: 0)),
        clarifyChain: [], tier: nil, resume: "self-test")
      try PlanFileJSON.encode(file).write(to: URL(filePath: plan.planFile))
      try LedgerJSON.encode(ledger).write(to: URL(filePath: plan.ledgerFile))
    } catch {
      return .blocked("could not write plan state: \(error)")
    }
    if let amended = try? String(
      contentsOf: caseDirectory.appending(path: "amended.md"), encoding: .utf8)
    {
      guard repo.write(designPath, amended), await repo.git("add", "-A"),
        await repo.git("commit", "-q", "-m", "amend")
      else { return .blocked("could not commit amended.md") }
    }

    let result = await PlanLintRun.run(
      slug: slug, root: repo.root, git: repo.git2, swiftPM: repo.swiftPM, harnessRoot: harnessRoot)
    switch result.outcome {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, _): return .blocked("invalid: \(reason)")
    case .checked(let checked):
      return .ruleIDs(Set(checked.findings.filter(\.severity.failsGate).map(\.ruleID)))
    }
  }

  // MARK: docs-lint

  private static let docsLintBaseConfig = """
    schema = 1
    xcode = "26.2"
    app_scheme = "Sample"
    packages = ["Sample"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    """

  /// The case's `docs/` subtree (and an optional root `AGENTS.md`), staged into a throwaway repo —
  /// `docs-lint` needs `git ls-files` for its tracked-file set, even with nothing committed — plus
  /// an optional `config.toml` fragment for the `[docs]` table a case needs.
  static func docsLint(caseDirectory: URL) async -> SeedRunOutcome {
    let docsSource = caseDirectory.appending(path: "docs", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(atPath: docsSource.path) else {
      return .blocked("no docs/ in this case")
    }
    let fragment =
      (try? String(contentsOf: caseDirectory.appending(path: "config.toml"), encoding: .utf8)) ?? ""

    let repo = SeedRepo.make(label: "docs-lint")
    defer { repo.remove() }
    do {
      try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
      try FileManager.default.copyItem(at: docsSource, to: repo.root.appending(path: "docs"))
    } catch {
      return .blocked("could not stage docs/: \(error)")
    }
    if !fragment.isEmpty, !repo.write(ConfigLoader.fileName, docsLintBaseConfig + fragment) {
      return .blocked("could not write \(ConfigLoader.fileName)")
    }
    let agents = caseDirectory.appending(path: "AGENTS.md")
    if FileManager.default.fileExists(atPath: agents.path),
      let text = try? String(contentsOf: agents, encoding: .utf8), !repo.write("AGENTS.md", text)
    {
      return .blocked("could not stage AGENTS.md")
    }

    guard await repo.git("init", "-q", "-b", "main"), await repo.git("add", "-A")
    else { return .blocked("could not init a temp git repo") }

    switch await DocsLintCheck.run(root: repo.root, runner: repo.runner) {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, _): return .blocked("invalid: \(reason)")
    case .checked(let result):
      return .ruleIDs(Set(result.findings.filter(\.severity.failsGate).map(\.ruleID)))
    }
  }

  // MARK: prose

  /// `prose` reads files off disk directly, with no git and, without a `.swiftgate.toml`, no
  /// config — the case's `doc.md` is checked in place, never copied into a throwaway repo.
  static func prose(caseDirectory: URL) async -> SeedRunOutcome {
    let fileName = "doc.md"
    guard FileManager.default.fileExists(atPath: caseDirectory.appending(path: fileName).path)
    else { return .blocked("no \(fileName) in this case") }
    switch ProseCheck.run(root: caseDirectory, files: [fileName]) {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, _): return .blocked("invalid: \(reason)")
    case .checked(let result):
      return .ruleIDs(Set(result.findings.filter(\.severity.failsGate).map(\.ruleID)))
    }
  }

  // MARK: comments

  /// `Seed.swift` staged (never committed — `comments` reads the index) into a throwaway repo. An
  /// optional `known-id.txt` names a ledger task id to seed under the repo's own common dir, so
  /// `comments.leaked-id`'s known-id half can fire without touching this checkout's shared plan
  /// state.
  static func comments(caseDirectory: URL) async -> SeedRunOutcome {
    guard
      let source = try? String(
        contentsOf: caseDirectory.appending(path: "Seed.swift"), encoding: .utf8)
    else { return .blocked("no Seed.swift in this case") }
    let knownID =
      (try? String(
        contentsOf: caseDirectory.appending(path: "known-id.txt"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let repo = SeedRepo.make(label: "comments")
    defer { repo.remove() }
    guard repo.write("Seed.swift", source), await repo.git("init", "-q", "-b", "main"),
      await repo.git("add", "-A")
    else { return .blocked("could not build the temp repo") }

    if let knownID, !knownID.isEmpty,
      await !repo.seedKnownID(knownID, slug: "self-test-comments")
    {
      return .blocked("could not seed the known-id feed")
    }

    switch await CommentsCheck.run(root: repo.root, git: repo.git2, swiftPM: repo.swiftPM) {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, _): return .blocked("invalid: \(reason)")
    case .checked(let result):
      return .ruleIDs(Set(result.findings.filter(\.severity.failsGate).map(\.ruleID)))
    }
  }

  // MARK: testlint

  /// `Tests/SeedTests/Seed.swift`, so ``PathConventionModuleScopes`` (no `.swiftgate.toml` here)
  /// classifies it as a test file — `test.leaked-id` and the rest of `testlint` only run over
  /// ``RuleScope/testFiles``. An optional `known-id.txt` names a ledger task id to seed under the
  /// repo's own common dir, mirroring `comments`' known-id case.
  static func testlint(caseDirectory: URL) async -> SeedRunOutcome {
    guard
      let source = try? String(
        contentsOf: caseDirectory.appending(path: "Seed.swift"), encoding: .utf8)
    else { return .blocked("no Seed.swift in this case") }
    let knownID =
      (try? String(
        contentsOf: caseDirectory.appending(path: "known-id.txt"), encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let repo = SeedRepo.make(label: "testlint")
    defer { repo.remove() }
    let relative = "Tests/SeedTests/Seed.swift"
    guard repo.write(relative, source), await repo.git("init", "-q", "-b", "main"),
      await repo.git("add", "-A")
    else { return .blocked("could not build the temp repo") }

    if let knownID, !knownID.isEmpty,
      await !repo.seedKnownID(knownID, slug: "self-test-testlint")
    {
      return .blocked("could not seed the known-id feed")
    }

    switch await TestlintCheck.run(
      root: repo.root, paths: [relative], swiftPM: repo.swiftPM, git: repo.git2)
    {
    case .blocked(let reason): return .blocked(reason)
    case .invalid(let reason, _): return .blocked("invalid: \(reason)")
    case .checked(let result):
      return .ruleIDs(Set(result.findings.filter(\.severity.failsGate).map(\.ruleID)))
    }
  }
}

struct SelfTestCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "self-test",
    abstract: "Prove every rule trips on its seeded violations and passes clean code.")

  static let harnessRootVariable = "SWIFTGATE_HARNESS_ROOT"

  @Option(
    help:
      "The swift-harness checkout to test. Default: $SWIFTGATE_HARNESS_ROOT (set by bin/swiftgate)."
  )
  var harnessRoot: String?

  @Option(
    help:
      "The clean sample app that must pass lint, testlint and arch. Default: \(SelfTest.sampleDirectory) in the git checkout that holds the harness root."
  )
  var sampleApp: String?

  @Flag(
    help: "Calibrate the judge instead: precision and recall per question on gate/Fixtures/judge.")
  var judge = false

  @Option(
    help: ArgumentHelp(
      "With --judge: answer with a live backend (claude) instead of the stored recording. "
        + "Costs money and sends the calibration set to the backend."))
  var judgeBackend: JudgeBackend?

  @Option(help: "With --judge-backend: the backend's model.")
  var model = JudgeFactory.defaultModel

  @Flag(help: "With --judge-backend: replace the stored recording with the live answers.")
  var record = false

  @OptionGroup var output: OutputOptions

  func validate() throws {
    if !judge, judgeBackend != nil || record {
      throw ValidationError("--judge-backend and --record need --judge")
    }
    if record, judgeBackend == nil { throw ValidationError("--record needs --judge-backend") }
  }

  func run() async throws {
    guard
      let path = harnessRoot ?? ProcessInfo.processInfo.environment[Self.harnessRootVariable]
    else {
      throw ValidationError(
        "pass --harness-root, or run through bin/swiftgate, which sets \(Self.harnessRootVariable)")
    }
    let root = CanonicalPath.url(URL(filePath: path, directoryHint: .isDirectory))
    if judge {
      let live = judgeBackend.flatMap {
        JudgeFactory.make(
          .enabled(backend: $0, thresholds: JudgeThresholds(advisory: 0, block: 1), model: model),
          runner: LiveProcessRunner(), cacheDirectory: nil)
      }
      try await StaticCheckRun.execute(root: root, format: output.format) {
        await JudgeSelfTest.run(harnessRoot: root, judge: live, record: record)
      }
      return
    }
    try await StaticCheckRun.execute(root: root, format: output.format) {
      await SelfTest.run(
        harnessRoot: root,
        sampleApp: sampleApp.map {
          CanonicalPath.url(URL(filePath: $0, directoryHint: .isDirectory))
        })
    }
  }
}
