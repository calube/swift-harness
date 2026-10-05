import ArgumentParser
import Foundation
import SwiftGateAdapters
import SwiftGateDomain

/// `test-only <id>`: 1 test through a brownfield area's own test command, narrowed to `id`, with
/// no baseline, prove or lint. It compiles what the test needs and runs it, so a fixer or worker
/// iterates on a compile or test failure in a fraction of a merge gate.
enum TestOnlyCheck {
  struct Dependencies: Sendable {
    let areas: [BrownfieldArea]
    let layout: BrownfieldStateLayout
    let trackedTree: TrackedTreeSnapshot
    let runner: any AreaCommandRunning
    let xcresults: any XcresultReader
    /// Per command run.
    let deadline: Duration

    /// The clone's config and state, and `/bin/sh` commands.
    static func live(root: URL) async throws(BrownfieldCheckSetupError) -> Dependencies {
      let merge = try await BrownfieldMergeCheck.Dependencies.live(root: root)
      return Dependencies(
        areas: merge.config.areas, layout: merge.layout, trackedTree: merge.trackedTree,
        runner: merge.runner, xcresults: LiveXcresultReader(runner: LiveProcessRunner()),
        deadline: BrownfieldMergeCheck.Dependencies.liveDeadline)
    }
  }

  /// - Parameters:
  ///   - test: what the area's filter takes: `<Target>/<Class>[/<method>]` for an `xcode` area.
  ///   - area: the area to run it in; `nil` takes the 1 area that runs tests.
  static func run(
    root: URL, test: String, area: String?, context: GateRun.Context,
    dependencies: Dependencies
  ) async throws -> GateRunParts {
    try BrownfieldCheck.notRun(.slice, because: "test-only isn't built yet")
  }
}

struct TestOnlyCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test-only",
    abstract:
      "Compile and run 1 test through a brownfield area's test command, with no baseline or "
      + "prove: the cheap loop before a merge gate.")

  @Argument(help: "The test, as the area's filter takes it: <Target>/<Class>[/<method>] in Xcode.")
  var test: String

  @Option(help: "The area to run it in; defaults to the 1 area with a test command.")
  var area: String?

  @OptionGroup var output: OutputOptions

  func run() async throws {
    let cwd = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    let root =
      (try? await BrownfieldCheck.repositoryRoot(
        from: cwd, git: LiveGit(runner: LiveProcessRunner(), repositoryRoot: cwd.path))) ?? cwd
    try await GateRun.execute(root: root, format: output.format, command: "test-only") {
      context in
      let dependencies: TestOnlyCheck.Dependencies
      do throws(BrownfieldCheckSetupError) {
        dependencies = try await .live(root: root)
      } catch {
        return try BrownfieldCheck.notRun(.slice, because: error.reason)
      }
      return try await TestOnlyCheck.run(
        root: root, test: test, area: area, context: context, dependencies: dependencies)
    }
  }
}
