import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// This checkout's own `.swiftgate.toml` names files by path. A path that matches nothing turns
/// its setting off without a word: a budget no file carries, a prose exclusion that excludes
/// nothing, a managed file docs-lint never reads, a package the gate never builds.
@Suite("this repository's .swiftgate.toml names real paths")
struct RepositoryConfigPathsTests {
  static func tracked() async throws -> [String] {
    let output = try await LiveProcessRunner().run(
      ProcessInvocation(
        executable: "/usr/bin/git", arguments: ["ls-files", "-z"],
        workingDirectory: Fixture.checkoutRoot.path, timeout: .seconds(30)))
    #expect(output.status.isSuccess, "\(output.stderr.text)")
    return output.stdout.text.split(separator: "\0").map(String.init)
  }

  static func config() throws -> Config {
    try #require(try ConfigLoader().load(repositoryRoot: Fixture.checkoutRoot))
  }

  @Test(
    "every [docs.budgets.files] key, managed file and prose_exclude glob matches a tracked file — catches a docs setting silently switched off by a move"
  )
  func docsPathsMatchFiles() async throws {
    let files = try await Self.tracked()
    let docs = try Self.config().docs
    #expect(files.count > 100)

    #expect(!docs.budgets.files.isEmpty)
    let unbudgeted = docs.budgets.files.keys.filter { !files.contains($0) }.sorted()
    #expect(unbudgeted == [], "[docs.budgets.files] keys that name no tracked file")
    let linted = Set(
      try await DocsTreeReader(runner: LiveProcessRunner()).read(
        repositoryRoot: Fixture.checkoutRoot
      ).documents.map(\.path))
    let unread = docs.budgets.files.keys.filter { !linted.contains($0) }.sorted()
    #expect(unread == [], "[docs.budgets.files] keys docs-lint never reads, so never budgets")

    let unmanaged = docs.managedFiles.filter { !files.contains($0) }
    #expect(unmanaged == [], "managed_files that name no tracked file")

    #expect(!docs.proseExclude.isEmpty)
    let idle = docs.proseExclude.filter { glob in
      !files.contains { DocsConfig(proseExclude: [glob]).isProseExcluded($0) }
    }
    #expect(idle == [], "prose_exclude globs that match no tracked file")
  }

  @Test(
    "every package has a tracked Package.swift and every excluded directory holds tracked files — catches the gate building or excluding nothing after a move"
  )
  func packagesAndExclusionsMatchFiles() async throws {
    let files = try await Self.tracked()
    let config = try Self.config()

    #expect(!config.packages.isEmpty)
    let missing = config.packages.filter { !files.contains("\($0)/Package.swift") }
    #expect(missing == [], "packages without a tracked Package.swift")

    let empty = config.exclude.filter { directory in
      !files.contains { $0.hasPrefix(directory + "/") }
    }
    #expect(empty == [], "exclude entries with no tracked files under them")
  }
}
