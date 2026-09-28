import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("app build adapters")
struct AppBuildAdapterTests {
  @Test(
    "xcodebuild build runs through xcrun with the request's closed argv and its output lands in the log — catches an app build run as raw xcodebuild or without -skipMacroValidation"
  )
  func liveBuild() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "swiftgate-app-build-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = FakeProcessRunner { _ throws(ProcessRunnerError) in
      ProcessOutput(status: .exited(65), stdout: "** BUILD FAILED **", stderr: "")
    }
    let request = AppBuild.Request(
      container: .project(path: "/r/App.xcodeproj"), scheme: "App", derivedDataPath: "/d",
      resultBundlePath: "/b.xcresult")
    let log = directory.appending(path: "build.log").path

    let status = try await LiveXcodebuild(runner: runner).build(request, logPath: log)

    let invocation = try #require(runner.invocations.first)
    #expect(invocation.executable == "/usr/bin/xcrun")
    #expect(invocation.arguments == ["xcodebuild"] + request.arguments)
    #expect(invocation.arguments.starts(with: ["xcodebuild", "build"]))
    #expect(invocation.arguments.contains("-skipMacroValidation"))
    #expect(status == .exited(65))
    #expect(try String(contentsOfFile: log, encoding: .utf8).contains("** BUILD FAILED **"))
  }

  @Test(
    "an xcodebuild that can't launch is a BLOCKED error, never an exit status — catches a missing toolchain read as a failed or passing build"
  )
  func buildThatCannotLaunch() async throws {
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      throw .launchFailed(executable: invocation.executable, reason: "not found")
    }
    let request = AppBuild.Request(
      container: .project(path: "/r/App.xcodeproj"), scheme: "App", derivedDataPath: "/d",
      resultBundlePath: "/b.xcresult")

    let error = await #expect(throws: XcodebuildError.self) {
      try await LiveXcodebuild(runner: runner).build(request, logPath: "/nonexistent/build.log")
    }

    #expect(error?.verdict == .blocked)
    #expect(error?.message.contains("not found") == true)
  }

  @Test(
    "a build bundle is read with build-results alone, and a missing one is a BLOCKED read error — catches the app build asking a build-only bundle for a test tree"
  )
  func readBuildResults() async throws {
    let json = try Fixture.data("Xcresult/app-build-error.build-results.json")
    let missing = try Fixture.text("Xcresult/missing-bundle.build-results.stderr")
    let runner = FakeProcessRunner { invocation throws(ProcessRunnerError) in
      invocation.arguments.last == "/r/App.xcresult"
        ? ProcessOutput(
          status: .exited(0), stdout: CapturedStream(bytes: json), stderr: CapturedStream(),
          elapsed: .zero)
        : ProcessOutput(status: .exited(64), stderr: missing)
    }
    let reader = LiveXcresultReader(runner: runner)

    let data = try await reader.readBuildResults(bundlePath: "/r/App.xcresult")

    #expect(data == json)
    #expect(
      runner.invocations.map { [$0.executable] + $0.arguments } == [
        ["/usr/bin/xcrun", "xcresulttool", "get", "build-results", "--path", "/r/App.xcresult"]
      ])
    let error = await #expect(throws: XcresultReadError.self) {
      try await reader.readBuildResults(bundlePath: "/SCRATCH/missing.xcresult")
    }
    #expect(error?.verdict == .blocked)
  }
}
