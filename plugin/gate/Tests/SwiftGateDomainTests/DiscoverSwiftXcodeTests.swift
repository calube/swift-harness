import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured repository as discover sees it: its listing, and each signal file's bytes. The
/// Xcode captures store Swift manifests with a `.txt` suffix, which the read strips.
private func capturedTree(_ relative: String) throws -> TrackedTreeSnapshot {
  let directory = Fixture.directory.appending(path: relative, directoryHint: .isDirectory)
  let listing = try String(contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
  let tree = directory.appending(path: "tree", directoryHint: .isDirectory)
  return TrackedTreeSnapshot(
    paths: listing.split(separator: "\n").map(String.init),
    read: { path in
      (try? Data(contentsOf: tree.appending(path: path)))
        ?? (try? Data(contentsOf: tree.appending(path: path + ".txt")))
    })
}

private func xcodeAreas(_ relative: String) throws -> [ProposedArea] {
  XcodeReader().areas(in: try capturedTree(relative))
}

@Suite("discover reads SwiftPM packages and Xcode projects")
struct DiscoverSwiftXcodeTests {
  @Test(
    "each captured Xcode project yields its inclusion kind — catches a Tuist manifest read as SwiftPM or a synchronized project read as explicit",
    arguments: [
      ("Xcode/synchronized", XcodeInclusion.synchronized, "."),
      ("Xcode/explicit", .explicit, "ios"),
      ("Xcode/xcodegen", .xcodegen, "Tests/Fixtures/SPM"),
      ("Xcode/tuist", .tuist, "examples/xcode/generated_app_with_framework_and_tests"),
    ])
  func inclusionKind(fixture: String, inclusion: XcodeInclusion, root: String) throws {
    let areas = try xcodeAreas(fixture)

    #expect(areas.map(\.root) == [root])
    #expect(areas.first?.kind == .xcode)
    #expect(areas.first?.xcode?.value.inclusion == inclusion)
  }

  @Test(
    "a Tuist manifest is no package and a Swift file named Project.swift is no Tuist manifest — catches readers keyed on a file name alone"
  )
  func tuistManifestsByContent() throws {
    let tuist = try capturedTree("Xcode/tuist")
    #expect(SwiftPMReader().areas(in: tuist).isEmpty)

    let workflow = try capturedTree("Discover/square-workflow-swift")
    #expect(SwiftPMReader().areas(in: workflow).map(\.root) == ["."])
    let samples = try #require(XcodeReader().areas(in: workflow).only)
    #expect(samples.root == "Samples")
    #expect(samples.xcode?.value.inclusion == .tuist)
    #expect(samples.xcode?.value.manifest == "Samples/Workspace.swift")
    #expect(samples.xcode?.value.workspace == "Samples/WorkflowDevelopment.xcworkspace")
    #expect(
      samples.xcode?.value.schemes == [
        "Documentation", "SnapshotTests", "TutorialTests", "UnitTests",
      ])

    let xcodeGen = try capturedTree("Discover/yonaskolb-XcodeGen")
    #expect(
      !XcodeReader().areas(in: xcodeGen).contains {
        $0.source == "Sources/ProjectSpec/Project.swift"
      }
    )
  }

  @Test(
    "a generator's committed project is recorded as tracked and an ignored one as untracked — catches the warm-up regenerating over a committed project or skipping an ignored one"
  )
  func generatedProjectTracked() throws {
    let xcodeGen = try #require(try xcodeAreas("Xcode/xcodegen").only)
    #expect(xcodeGen.generatedProjectTracked == true)
    #expect(xcodeGen.xcode?.value.project == "Tests/Fixtures/SPM/SPM.xcodeproj")
    #expect(xcodeGen.xcode?.value.manifest == "Tests/Fixtures/SPM/project.yml")

    let tuist = try #require(try xcodeAreas("Xcode/tuist").only)
    #expect(tuist.generatedProjectTracked == false)
    #expect(
      tuist.xcode?.value.workspace
        == "examples/xcode/generated_app_with_framework_and_tests/App.xcworkspace")
    #expect(tuist.xcode?.value.schemes == ["AppCustomScheme"])

    let explicit = try #require(try xcodeAreas("Xcode/explicit").only)
    #expect(explicit.generatedProjectTracked == nil)
  }

  @Test(
    "a package beside or inside an Xcode workspace is 1 area, not 2 — catches the same sources gated twice"
  )
  func packageInsideWorkspaceIsOneArea() throws {
    let alamofire = try capturedTree("Discover/Alamofire-Alamofire")
    let proposal = Discover.propose(tree: alamofire, head: "abc", dirty: [])
    let swift = proposal.areas.filter { $0.language == .swift }
    #expect(swift.map(\.root) == ["."])
    let area = try #require(swift.only)
    #expect(area.kind == .xcode)
    #expect(area.xcode?.value.workspace == "Alamofire.xcworkspace")
    #expect(area.xcode?.value.project == nil)

    let xcodeGen = try capturedTree("Discover/yonaskolb-XcodeGen")
    let packages = SwiftPMReader().areas(in: xcodeGen).map(\.root)
    #expect(!packages.contains("Tests/Fixtures/SPM/FooFeature"))
    #expect(!packages.contains("Tests/Fixtures/LocalPackage"))
    #expect(packages.contains("."))
    #expect(packages.contains("Tests/Fixtures/paths_test/relative_local_package/LocalPackage"))
  }

  @Test(
    "schemes come from shared .xcscheme files only and the test command uses 1 with a test target — catches a user's xcuserdata scheme or a scheme with no tests"
  )
  func sharedSchemes() throws {
    let buy = try #require(try xcodeAreas("Discover/Shopify-mobile-buy-sdk-ios").only)
    #expect(buy.xcode?.value.schemes == ["Buy", "Buy tvOS", "Buy watchOS", "BuyTests"])
    #expect(buy.xcode?.value.project == "Buy.xcodeproj")
    let build = try #require(buy.commands[.build])
    #expect(
      build.value
        == "xcodebuild build -project Buy.xcodeproj -scheme Buy -destination 'generic/platform=iOS Simulator' -skipMacroValidation -skipPackagePluginValidation"
    )
    #expect(build.source == "Buy.xcodeproj/xcshareddata/xcschemes/Buy.xcscheme")
    let test = try #require(buy.commands[.test])
    #expect(test.value.hasPrefix("xcodebuild test -project Buy.xcodeproj -scheme Buy "))
    #expect(test.confidence == .guessed)
    #expect(buy.testGlobs == ["**/BuyTests/**/*.swift"])
    #expect(buy.commands[.lint]?.value == "swiftlint lint --config .swiftlint.yml {files}")

    let alamofire = try #require(
      try xcodeAreas("Discover/Alamofire-Alamofire").first { $0.root == "." })
    #expect(
      alamofire.commands[.test]?.value.contains("-scheme 'Alamofire iOS'") == true,
      "with no scheme named after the area, the iOS one is preferred")

    let schemeTest = try #require(
      try xcodeAreas("Discover/yonaskolb-XcodeGen").first {
        $0.root == "Tests/Fixtures/scheme_test"
      })
    #expect(schemeTest.xcode?.value.schemes == ["ExternalTarget", "Shared_TargetScheme"])
  }

  @Test(
    "a project that depends on a package plugin gets build and test commands that skip plugin validation — catches a headless build that stops at the plugin trust prompt"
  )
  func packagePluginValidationSkipped() throws {
    let tree = try capturedTree("Xcode/xcodegen")
    let pbxproj = "Tests/Fixtures/SPM/SPM.xcodeproj/project.pbxproj"
    let project = try #require(tree.read(pbxproj).map { String(decoding: $0, as: UTF8.self) })
    #expect(project.contains("productName = \"plugin:PrefirePlaybookPlugin\";"))

    let area = try #require(XcodeReader().areas(in: tree).only)
    let build = try #require(area.commands[.build]?.value)
    #expect(build.hasPrefix("xcodebuild build "))
    #expect(build.contains(" -skipMacroValidation"))
    #expect(build.hasSuffix(" -skipPackagePluginValidation"))
    #expect(area.commands[.test] == nil, "no shared scheme here has a test target")

    let buy = try #require(try xcodeAreas("Discover/Shopify-mobile-buy-sdk-ios").only)
    let test = try #require(buy.commands[.test]?.value)
    #expect(test.hasPrefix("xcodebuild test "))
    #expect(test.hasSuffix(" -skipMacroValidation -skipPackagePluginValidation"))
  }

  @Test(
    "a workspace claims the projects it references, and a project's own workspace is never an area — catches an area per embedded project.xcworkspace"
  )
  func workspaceClaimsProjects() throws {
    let alamofire = try xcodeAreas("Discover/Alamofire-Alamofire")
    #expect(alamofire.map(\.root) == ["."])

    let llama = try xcodeAreas("Discover/ggml-org-llama.cpp")
    #expect(llama.map(\.root) == ["examples/llama.swiftui"])
    #expect(
      llama.first?.xcode?.value.project == "examples/llama.swiftui/llama.swiftui.xcodeproj")
    #expect(llama.first?.missing[.build] != nil, "no shared scheme is tracked")
  }

  @Test(
    "a package yields swift build and swift test with a filter in its own root, from Package.swift only — catches a Package@swift variant as a second area"
  )
  func swiftPMCommands() throws {
    let llama = try capturedTree("Discover/ggml-org-llama.cpp")
    let batched = try #require(SwiftPMReader().areas(in: llama).only)
    #expect(batched.root == "examples/batched.swift")
    #expect(batched.name == "batched.swift")
    #expect(batched.commands[.build]?.value == "swift build")
    #expect(batched.missing[.test] != nil, "the package declares no test target")
    #expect(batched.commands[.test] == nil)

    let xcodeGen = try capturedTree("Discover/yonaskolb-XcodeGen")
    let root = try #require(SwiftPMReader().areas(in: xcodeGen).first { $0.root == "." })
    #expect(root.name == "XcodeGen")
    #expect(
      root.commands[.testFiles]
        == Sourced(
          value: "swift test --filter {tests}", source: "Package.swift", confidence: .found))
    #expect(root.commands[.lint]?.value == "swiftformat --lint --config .swiftformat {files}")
    #expect(root.testGlobs == ["Tests/**/*.swift"])

    let alamofire = try capturedTree("Discover/Alamofire-Alamofire")
    #expect(SwiftPMReader().areas(in: alamofire).isEmpty)
  }

  @Test(
    "build output on disk never becomes a Swift area — catches a reader that walks the filesystem"
  )
  func afterBuildYieldsNothingNew() throws {
    let tree = try capturedTree("Discover/Alamofire-Alamofire")
    let directory = Fixture.directory.appending(path: "Discover/Alamofire-Alamofire/after-build")
    let listing = try String(
      contentsOf: directory.appending(path: "ls-files.txt"), encoding: .utf8)
    let afterBuild = TrackedTreeSnapshot(
      paths: listing.split(separator: "\n").map(String.init), read: tree.read)
    let ignored = try String(
      contentsOf: directory.appending(path: "status-ignored.txt"), encoding: .utf8)
    #expect(ignored.contains(".build/"))

    let before = Discover.propose(tree: tree, head: "abc", dirty: []).areas
    let after = Discover.propose(tree: afterBuild, head: "abc", dirty: []).areas
    #expect(after == before)
    #expect(!after.contains { $0.root.hasPrefix(".build") })
    #expect(!before.isEmpty)
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}
