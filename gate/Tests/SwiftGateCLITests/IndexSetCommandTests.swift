import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@testable import SwiftGateCLI

/// A throwaway git repository plus one linked worktree, used only to prove that two different
/// worktree roots resolve to the same shared plan index (spec §4: the git common dir, not
/// `.harness/`, is what every linked worktree shares).
private struct LinkedWorktreePair {
  static let environment: [String: String] = [
    "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin",
    "HOME": FileManager.default.temporaryDirectory.path,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
  ]

  let mainRoot: URL
  let linkedRoot: URL
  let runner: LiveProcessRunner

  var mainGit: LiveGit { LiveGit(runner: runner, repositoryRoot: mainRoot.path) }
  var linkedGit: LiveGit { LiveGit(runner: runner, repositoryRoot: linkedRoot.path) }

  /// A free function, not an instance method: a struct may not call `self.git` before every
  /// stored property (`linkedRoot`) has its first assignment.
  @discardableResult
  private static func git(_ runner: LiveProcessRunner, in directory: URL, _ arguments: String...)
    async throws -> String
  {
    let output = try await runner.run(
      ProcessInvocation(
        executable: "git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(30)))
    guard output.status.isSuccess else {
      struct Failure: Error { let stderr: String }
      throw Failure(stderr: output.stderr.text)
    }
    return output.stdout.text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  init() async throws {
    let runner = LiveProcessRunner(baseEnvironment: Self.environment)
    let mainRoot = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-index-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: mainRoot, withIntermediateDirectories: true)
    try await Self.git(runner, in: mainRoot, "init", "-q", "-b", "main")
    try await Self.git(runner, in: mainRoot, "config", "commit.gpgsign", "false")
    try Data("a\n".utf8).write(to: mainRoot.appending(path: "A.swift"))
    try await Self.git(runner, in: mainRoot, "add", "-A")
    try await Self.git(runner, in: mainRoot, "commit", "-q", "-m", "base")

    let linkedRoot = mainRoot.deletingLastPathComponent()
      .appending(path: "\(mainRoot.lastPathComponent)-linked", directoryHint: .isDirectory)
    try await Self.git(runner, in: mainRoot, "worktree", "add", "-q", "-b", "task", linkedRoot.path)

    self.runner = runner
    self.mainRoot = mainRoot
    self.linkedRoot = linkedRoot
  }

  func remove() {
    try? FileManager.default.removeItem(at: linkedRoot)
    try? FileManager.default.removeItem(at: mainRoot)
  }
}

@Suite("swiftgate index set")
struct IndexSetCommandTests {
  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-index-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  /// A real ``FileCountingLock``, just polling faster than the production default so a test with
  /// many contended acquisitions doesn't spend most of its time asleep between polls.
  private func fastStore(_ path: String) -> PlanIndexStore {
    PlanIndexStore(
      path: path,
      lock: FileCountingLock(
        directory: URL(filePath: path).deletingLastPathComponent(), name: "index.lock",
        capacity: 1, pollInterval: .milliseconds(2)))
  }

  @Test(
    "N concurrent `index set` calls for different slugs all land — catches a lost update from an unlocked read-modify-write"
  )
  func concurrentSetsAllLand() async throws {
    // `swift test` 6.2 can't repeat a test, so the race is exercised by looping here instead.
    for iteration in 0..<20 {
      let directory = temporaryDirectory()
      defer { try? FileManager.default.removeItem(at: directory) }
      let git = FakeGit(commonDirectory: directory.path)
      let concurrency = 16
      let expectedSlugs = Set((0..<concurrency).map { "slug-\(iteration)-\($0)" })

      await withTaskGroup(of: Void.self) { group in
        for index in 0..<concurrency {
          group.addTask {
            let slug = "slug-\(iteration)-\(index)"
            let outcome = await IndexSetRun.run(
              slug: slug, status: "pending", resume: "resume-\(index)", git: git,
              store: fastStore)
            if case .failure(let error) = outcome {
              Issue.record("iteration \(iteration) slug \(slug) failed: \(error)")
            }
          }
        }
      }

      let layout = try PlanStateLayout(commonDirectory: directory.path)
      let data = try Data(contentsOf: URL(filePath: layout.indexFile))
      let index = try PlanIndex.decode(data)
      #expect(
        Set(index.plans.map(\.slug)) == expectedSlugs,
        "iteration \(iteration) lost an update: got \(index.plans.map(\.slug).sorted())")
      #expect(index.plans.count == concurrency, "iteration \(iteration) has duplicate entries")
    }
  }

  @Test(
    "readers never see a half-written index while writes race — catches a non-atomic write torn mid-read"
  )
  func concurrentWritesNeverTearTheFile() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = FakeGit(commonDirectory: directory.path)
    let layout = try PlanStateLayout(commonDirectory: directory.path)
    let writers = 12
    let readers = 12

    await withTaskGroup(of: Void.self) { group in
      for index in 0..<writers {
        group.addTask {
          let outcome = await IndexSetRun.run(
            slug: "writer-\(index)", status: "pending", resume: "r", git: git, store: fastStore)
          if case .failure(let error) = outcome {
            Issue.record("writer \(index) failed: \(error)")
          }
        }
      }
      for _ in 0..<readers {
        group.addTask {
          for _ in 0..<200 {
            // `contents(atPath:)` returns `nil` rather than throwing, so a poll that lands before
            // any writer has created the file is simply skipped, not treated as an error.
            guard let data = FileManager.default.contents(atPath: layout.indexFile) else {
              continue
            }
            do {
              _ = try PlanIndex.decode(data)
            } catch {
              Issue.record("read a non-JSON (torn) index while writers were racing: \(error)")
            }
          }
        }
      }
    }
  }

  @Test(
    "a malformed index.json is left untouched and reported BLOCKED — catches an update that clobbers unreadable state"
  )
  func malformedIndexIsLeftUntouched() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let layout = try PlanStateLayout(commonDirectory: directory.path)
    try FileManager.default.createDirectory(
      at: URL(filePath: layout.root), withIntermediateDirectories: true)
    let malformed = Data("{ not json".utf8)
    try malformed.write(to: URL(filePath: layout.indexFile))
    let git = FakeGit(commonDirectory: directory.path)

    let outcome = await IndexSetRun.run(slug: "s", status: "pending", resume: "r", git: git)
    guard case .failure(let error) = outcome else {
      Issue.record("expected a failure, got \(outcome)")
      return
    }
    #expect(error.verdict == .blocked)
    #expect(error.verdict.exitCode == 2)
    let after = try Data(contentsOf: URL(filePath: layout.indexFile))
    #expect(after == malformed, "the malformed file must be untouched")
  }

  @Test(
    "the main checkout and a linked worktree write into the same index.json — catches per-worktree plan state"
  )
  func linkedWorktreeWritesTheSharedIndex() async throws {
    let pair = try await LinkedWorktreePair()
    defer { pair.remove() }

    let first = await IndexSetRun.run(
      slug: "main-plan", status: "in-progress", resume: "from main", git: pair.mainGit)
    guard case .success = first else {
      Issue.record("expected success from the main checkout, got \(first)")
      return
    }
    let second = await IndexSetRun.run(
      slug: "linked-plan", status: "pending", resume: "from linked worktree", git: pair.linkedGit)
    guard case .success(let index) = second else {
      Issue.record("expected success from the linked worktree, got \(second)")
      return
    }

    #expect(Set(index.plans.map(\.slug)) == ["main-plan", "linked-plan"])
    let common = try await pair.mainGit.commonDirectory()
    #expect(try await pair.linkedGit.commonDirectory() == common)
    let layout = try PlanStateLayout(commonDirectory: common)
    let onDisk = try PlanIndex.decode(try Data(contentsOf: URL(filePath: layout.indexFile)))
    #expect(Set(onDisk.plans.map(\.slug)) == ["main-plan", "linked-plan"])
  }

  @Test("an upsert replaces the existing entry for a slug instead of duplicating it")
  func upsertReplacesExistingEntry() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let git = FakeGit(commonDirectory: directory.path)

    _ = await IndexSetRun.run(slug: "a", status: "pending", resume: "first", git: git)
    let outcome = await IndexSetRun.run(slug: "a", status: "done", resume: "second", git: git)

    guard case .success(let index) = outcome else {
      Issue.record("expected success, got \(outcome)")
      return
    }
    #expect(index.plans.count == 1)
    #expect(index.plans.first?.status == "done")
    #expect(index.plans.first?.resume == "second")
  }

  @Test(
    "`swiftgate gc` never touches the shared swift-harness/plans directory — catches gc pruning plan state"
  )
  func gcLeavesTheSharedPlanIndexAlone() async throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Model the shared state at `<git common dir>/swift-harness/plans`, aged well past gc's
    // default retention, sitting right next to the per-worktree `.harness/` gc actually prunes.
    let layout = try PlanStateLayout(
      commonDirectory: root.appending(path: ".git", directoryHint: .isDirectory).path)
    try FileManager.default.createDirectory(
      at: URL(filePath: layout.root), withIntermediateDirectories: true)
    let indexURL = URL(filePath: layout.indexFile)
    let contents = try PlanIndex(plans: [PlanSummary(slug: "s", status: "pending", resume: nil)])
      .encode()
    try contents.write(to: indexURL)
    let old = Date(timeIntervalSinceNow: -3600 * 24 * 365)
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: indexURL.path)

    _ = await GCRun.run(root: root, maxAgeDays: 7, now: Date()) { [String]() }

    #expect(FileManager.default.fileExists(atPath: indexURL.path))
    #expect(try Data(contentsOf: indexURL) == contents)
  }
}
