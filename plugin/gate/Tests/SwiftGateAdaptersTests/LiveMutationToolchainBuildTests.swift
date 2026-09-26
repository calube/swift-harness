import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A real `swift build` of the `Scorer` fixture package through ``LiveMutationToolchain``.
@Suite("LiveMutationToolchain building for real")
struct LiveMutationToolchainBuildTests {
  @Test(
    "a mutant build writes no debug symbols and uses only its share of the cores — catches every worker running dsymutil and a full-width compile at once, wedging the machine"
  )
  func buildSkipsDebugSymbolsAndSharesCores() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "swiftgate-mutant-build-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = directory.appending(path: "Scorer", directoryHint: .isDirectory)
    try FileManager.default.copyItem(
      at: Fixture.gateDirectory.appending(path: "Fixtures/mutate/Scorer"), to: package)
    try? FileManager.default.removeItem(at: package.appending(path: ".build"))
    // The real `swift`, run through a script that first records the arguments it was given.
    let arguments = directory.appending(path: "arguments")
    let swift = directory.appending(path: "swift")
    try Data(
      """
      #!/bin/sh
      printf '%s\\n' "$@" > "\(arguments.path)"
      exec swift "$@"

      """.utf8
    ).write(to: swift)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let result = await LiveMutationToolchain(runner: LiveProcessRunner(), executable: swift.path)
      .buildTests(root: directory, packageDirectory: "Scorer", jobs: 3)

    #expect(result == .built)
    let given = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n")
    #expect(given.contains(["--jobs", "3"]))
    let products = package.appending(path: ".build").path
    let symbols = FileManager.default.enumerator(atPath: products)?
      .compactMap { $0 as? String }.filter { $0.hasSuffix(".dSYM") }
    #expect(symbols == [])
  }
}
