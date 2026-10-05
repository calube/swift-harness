import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// `qa stage`: a flow repair round's prepared folder, filled from plan state by swiftgate so the
/// orchestrator never copies a store file with a shell `cp` a user alias can turn interactive.
@Suite("qa stage")
struct QAStageTests {
  static func stage(_ repo: QARepo, worktree: String? = nil, plan: String, requirement: String)
    async -> QAStageReport
  {
    await QAStageRun.run(
      worktree: worktree ?? repo.root.path, plan: plan, requirement: requirement, root: repo.root,
      git: LiveGit(runner: repo.runner, repositoryRoot: repo.root.path), runner: repo.runner)
  }

  /// Every file under `directory`, relative to it, sorted.
  static func tree(_ directory: URL) -> [String] {
    let base = directory.resolvingSymlinksInPath().path + "/"
    let walker = FileManager.default.enumerator(atPath: directory.path)
    var names: [String] = []
    while let name = walker?.nextObject() as? String {
      var isDirectory: ObjCBool = false
      let path = directory.appending(path: name).path
      if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        !isDirectory.boolValue
      {
        names.append(String(directory.appending(path: name).resolvingSymlinksInPath().path
          .dropFirst(base.count)))
      }
    }
    return names.sorted()
  }

  /// A worker's leftovers in the checkout's prepared folder: another plan's folder, and a file
  /// beside the requirement's flow.
  static func leaveStaleFiles(in repo: QARepo, slug: String) throws {
    let prepared = repo.root.appending(path: ".harness/qa", directoryHint: .isDirectory)
    for path in ["other-plan/old.flow.json", "\(slug)/stray.flow.json"] {
      let file = prepared.appending(path: path)
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("[]".utf8).write(to: file)
    }
  }

  @Test(
    "on the trial's refresh row, staging its requirement leaves the checkout's .harness/qa holding only that plan's adopted flow, byte for byte, with the other plan's folder and the stray file gone — catches a repair worker starting from leftovers, or a store file the orchestrator copies by hand"
  )
  func stagesTheTrialRequirement() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QAAdoptRepairTests.trial(repo)
    try Self.leaveStaleFiles(in: repo, slug: RefreshRepairTrial.plan)

    let report = await Self.stage(
      repo, plan: RefreshRepairTrial.plan, requirement: RefreshRepairTrial.requirement)

    #expect(report.verdict == .green, "\(report.message)")
    #expect(report.files == [RefreshRepairTrial.fileName])
    let prepared = repo.root.appending(path: ".harness/qa", directoryHint: .isDirectory)
    #expect(Self.tree(prepared) == ["\(RefreshRepairTrial.plan)/\(RefreshRepairTrial.fileName)"])
    #expect(
      try Data(
        contentsOf: prepared.appending(
          path: "\(RefreshRepairTrial.plan)/\(RefreshRepairTrial.fileName)"))
        == (try RefreshRepairTrial.adoptedFlow()))
    #expect(report.destination.hasSuffix(".harness/qa/\(RefreshRepairTrial.plan)"))
  }

  @Test(
    "staging a state row copies only its requirement's script and keeps it executable — catches another requirement's check staged, or a state script that can no longer run"
  )
  func keepsAStateScriptExecutable() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try repo.plan(
      [
        validationRow("req-total", .state, "qa/total.sh", after: ["total-ui"]),
        validationRow("req-other", .state, "qa/other.sh", after: ["other-ui"]),
      ], tasks: ["total-ui": .pending, "other-ui": .pending])
    try repo.qaFile("total.sh", "exit 0\n", executable: true)
    try repo.qaFile("other.sh", "exit 0\n", executable: true)

    let report = await Self.stage(repo, plan: QARepo.slug, requirement: "req-total")

    #expect(report.verdict == .green, "\(report.message)")
    let prepared = repo.root.appending(path: ".harness/qa", directoryHint: .isDirectory)
    #expect(Self.tree(prepared) == ["\(QARepo.slug)/total.sh"])
    let attributes = try FileManager.default.attributesOfItem(
      atPath: prepared.appending(path: "\(QARepo.slug)/total.sh").path)
    #expect((attributes[.posixPermissions] as? Int) == 0o755)
  }

  @Test(
    "a path that isn't a checkout, a requirement no row checks with a qa/ file, or a row whose file plan state lacks is refused with the prepared folder untouched — catches a half-staged folder or one emptied for nothing"
  )
  func refusesWithNothingTouched() async throws {
    let repo = try await QARepo()
    defer { repo.remove() }
    try QAAdoptRepairTests.trial(repo)
    try Self.leaveStaleFiles(in: repo, slug: RefreshRepairTrial.plan)
    let prepared = repo.root.appending(path: ".harness/qa", directoryHint: .isDirectory)
    let before = Self.tree(prepared)
    let elsewhere = repo.root.deletingLastPathComponent().appending(path: "not-a-checkout").path

    let outside = await Self.stage(
      repo, worktree: elsewhere, plan: RefreshRepairTrial.plan,
      requirement: RefreshRepairTrial.requirement)
    let unknown = await Self.stage(
      repo, plan: RefreshRepairTrial.plan, requirement: "req-nope")
    try FileManager.default.removeItem(
      at: repo.planDirectory(RefreshRepairTrial.plan).appending(path: RefreshRepairTrial.check))
    let missing = await Self.stage(
      repo, plan: RefreshRepairTrial.plan, requirement: RefreshRepairTrial.requirement)

    #expect(outside.verdict == .red, "\(outside.message)")
    #expect(outside.message.contains("not a checkout"), "\(outside.message)")
    #expect(unknown.verdict == .red, "\(unknown.message)")
    #expect(unknown.message.contains("req-nope"), "\(unknown.message)")
    #expect(missing.verdict == .red, "\(missing.message)")
    #expect(missing.message.contains(RefreshRepairTrial.fileName), "\(missing.message)")
    #expect(Self.tree(prepared) == before)
  }
}
