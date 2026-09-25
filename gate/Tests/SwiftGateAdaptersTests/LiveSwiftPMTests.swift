import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("LiveSwiftPM")
struct LiveSwiftPMTests {
  private let root = Fixture.repositoryRoot
  private let gameEngine = "examples/SampleApp/Packages/GameEngine"

  private func adapter(_ runner: FakeProcessRunner) -> LiveSwiftPM {
    LiveSwiftPM(runner: runner, repositoryRoot: root)
  }

  @Test(
    "describe runs in the package directory and decodes its JSON — catches describing the wrong package"
  )
  func describe() async throws {
    let json = try Fixture.text("SwiftPM/describe-GameEngine.json")
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0), stdout: json) }

    let manifest = try await adapter(runner).describe(packageDirectory: gameEngine)

    #expect(manifest.path == gameEngine)
    #expect(manifest.targets.map(\.name).sorted() == ["GameEngine", "GameEngineTests"])
    let invocation = try #require(runner.invocations.first)
    #expect(invocation.executable == "swift")
    #expect(invocation.arguments == ["package", "describe", "--type", "json"])
    #expect(invocation.workingDirectory == "\(root)/\(gameEngine)")
  }

  @Test(
    "settings runs dump-package in the package directory — catches isolation read from the wrong package"
  )
  func settings() async throws {
    let json = try Fixture.text("SwiftPM/dump-package-main-actor-core.json")
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0), stdout: json) }

    let settings = try await adapter(runner).settings(packageDirectory: gameEngine)

    #expect(settings.defaultIsolation["FeedCore"] == "MainActor")
    let invocation = try #require(runner.invocations.first)
    #expect(invocation.arguments == ["package", "dump-package"])
    #expect(invocation.workingDirectory == "\(root)/\(gameEngine)")
  }

  @Test(
    "describe failure is blocked with swift's stderr — catches a missing package passing as empty")
  func describeFailure() async throws {
    let stderr = try Fixture.text("SwiftPM/describe-no-package.stderr.txt")
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(1), stderr: stderr) }

    await #expect {
      _ = try await adapter(runner).describe(packageDirectory: "nowhere")
    } throws: { error in
      guard let error = error as? SwiftPMError,
        case .commandFailed(_, let status, let message) = error
      else { return false }
      return status == .exited(1) && message.contains("Could not find Package.swift")
        && error.verdict == .blocked
    }
  }

  @Test("describe timeout surfaces as a process error — catches a hung resolve reported as green")
  func describeTimeout() async {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .timedOut(
        executable: invocation.executable, after: .seconds(1), stdout: CapturedStream(),
        stderr: CapturedStream())
    }
    await #expect {
      _ = try await adapter(runner).describe(packageDirectory: gameEngine)
    } throws: { error in
      guard case .process(.timedOut)? = error as? SwiftPMError else { return false }
      return true
    }
  }

  @Test(
    "test builds argv, forces snapshot record=never, and names both xUnit files — catches implicit snapshot recording"
  )
  func testInvocation() async throws {
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(1), stdout: "failed") }
    let request = SwiftTestRequest(
      packageDirectory: gameEngine, filters: ["GameEngineTests\\."], parallel: true,
      codeCoverage: true, xunitOutputPath: "/runs/abc/GameEngine.xml")

    let run = try await adapter(runner).test(request)

    let invocation = try #require(runner.invocations.first)
    #expect(
      invocation.arguments == [
        "test", "--parallel", "--enable-code-coverage", "--xunit-output",
        "/runs/abc/GameEngine.xml", "--filter", "GameEngineTests\\.",
      ])
    #expect(invocation.workingDirectory == "\(root)/\(gameEngine)")
    #expect(invocation.environmentOverlay["SNAPSHOT_TESTING_RECORD"] == .some("never"))
    #expect(run.output.status == .exited(1))
    #expect(run.xctestReportPath == "/runs/abc/GameEngine.xml")
    #expect(run.swiftTestingReportPath == "/runs/abc/GameEngine-swift-testing.xml")
  }

  @Test("coverage path is read from swift's output — catches coverage parsed from a stale location")
  func codeCoveragePath() async throws {
    let output = try Fixture.text("SwiftPM/show-codecov-path-GameEngine.txt")
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0), stdout: output) }

    let path = try await adapter(runner).codeCoveragePath(packageDirectory: gameEngine)

    #expect(path == "/REPO/\(gameEngine)/.build/arm64-apple-macosx/debug/codecov/GameEngine.json")
    #expect(runner.invocations.first?.arguments == ["test", "--show-codecov-path"])
  }

  @Test("a non-path coverage answer is rejected — catches reading coverage from garbage")
  func codeCoveragePathGarbage() async {
    let runner = FakeProcessRunner { _ in ProcessOutput(status: .exited(0), stdout: "warning: x\n")
    }
    await #expect {
      _ = try await adapter(runner).codeCoveragePath(packageDirectory: gameEngine)
    } throws: { error in
      guard case .unparseableOutput? = error as? SwiftPMError else { return false }
      return true
    }
  }

  @Test(
    "the recorded describe fixture still matches a real run — catches stale fixtures or describe format drift"
  )
  func fixtureMatchesRealDescribe() async throws {
    let checkout = Fixture.checkoutRoot.resolvingSymlinksInPath().path
    let live = LiveSwiftPM(runner: LiveProcessRunner(), repositoryRoot: checkout)

    let real = try await live.describe(packageDirectory: gameEngine)
    let recorded = try PackageManifest(
      describeJSON: Fixture.data("SwiftPM/describe-GameEngine.json"), repositoryRoot: root)

    #expect(real == recorded)
  }
}
