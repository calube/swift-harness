import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("ConfigLoader profile")
struct ConfigLoaderProfileTests {
  let loader = ConfigLoader()

  /// A worktree root with its own `.git` directory, standing in for a fresh clone.
  func makeClone() throws -> (root: URL, common: URL) {
    let root = TestTemporaryDirectory.root
      .appending(path: "swiftgate-profile-\(UUID().uuidString)", directoryHint: .isDirectory)
    let common = root.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
    return (root, common)
  }

  func writeCommonConfig(_ common: URL) throws -> URL {
    let file = common.appending(path: StateRootResolver.commonConfigFile)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(BrownfieldConfigTOMLSample.text.utf8).write(to: file)
    return file
  }

  @Test(
    "a clone with both configs fails with a conflict naming both paths — catches the committed config silently winning"
  )
  func bothConfigsConflict() throws {
    let (root, common) = try makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    let committed = root.appending(path: ConfigLoader.fileName)
    try Data(TOMLConfigDecoderTests.minimal.utf8).write(to: committed)
    let commonFile = try writeCommonConfig(common)

    #expect(throws: ProfileLoadError.conflict(committed: committed.path, common: commonFile.path)) {
      try loader.loadProfile(repositoryRoot: root, commonDir: common)
    }
  }

  @Test(
    "a clone with only the common-dir config loads the brownfield profile, and one with only the committed config stays owned — catches either profile read as the other"
  )
  func eachConfigLoadsItsProfile() throws {
    let (root, common) = try makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    let (owned, ownedCommon) = try makeClone()
    defer { try? FileManager.default.removeItem(at: owned) }
    _ = try writeCommonConfig(common)
    try Data(TOMLConfigDecoderTests.minimal.utf8)
      .write(to: owned.appending(path: ConfigLoader.fileName))

    let expected = try TOMLConfigDecoder().decodeBrownfield(BrownfieldConfigTOMLSample.text)
    #expect(
      try loader.loadProfile(repositoryRoot: root, commonDir: common) == .brownfield(expected))
    let ownedConfig = try #require(try loader.load(repositoryRoot: owned))
    #expect(
      try loader.loadProfile(repositoryRoot: owned, commonDir: ownedCommon) == .owned(ownedConfig))
  }

  @Test(
    "a broken common-dir config is RED and names its own path — catches it reported as the committed file"
  )
  func brokenCommonConfigNamesItself() throws {
    let (root, common) = try makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = common.appending(path: StateRootResolver.commonConfigFile)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("schema = \n".utf8).write(to: file)

    do {
      _ = try loader.loadProfile(repositoryRoot: root, commonDir: common)
      Issue.record("a broken config loaded")
    } catch {
      #expect(error.verdict == .red)
      #expect(error.description.contains(file.path))
    }
  }

  @Test(
    "a linked worktree's common dir is the main checkout's git dir — catches each worktree reading its own config"
  )
  func linkedWorktreeSharesCommonDir() async throws {
    let (root, common) = try makeClone()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: common)
    let linked = root.appending(path: "linked", directoryHint: .isDirectory)
    try await git(["init", "-q", "-b", "main"], in: root)
    try await git(
      ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "i"],
      in: root)
    try await git(["worktree", "add", "-q", linked.path], in: root)

    let found = try #require(ConfigLoader.commonDirectory(enclosing: linked))
    #expect(found.resolvingSymlinksInPath().path == common.resolvingSymlinksInPath().path)
  }

  private func git(_ arguments: [String], in directory: URL) async throws {
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "/usr/bin/git", arguments: arguments, workingDirectory: directory.path,
        timeout: .seconds(60)))
    #expect(
      output.status.isSuccess, "git \(arguments.joined(separator: " ")): \(output.stderr.text)")
  }
}
