import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// A captured `F/Xcode/<case>/` project: its `project.pbxproj` and where the `.xcodeproj` sits in
/// the repository it came from.
struct CapturedXcodeProject: Sendable, CustomTestStringConvertible {
  let name: String
  /// The captured file, relative to `F/Xcode/<case>/`.
  let file: String
  let projectPath: String

  var testDescription: String { name }

  static let synchronized = CapturedXcodeProject(
    name: "synchronized", file: "tree/Buy.xcodeproj/project.pbxproj",
    projectPath: "Buy.xcodeproj")
  static let explicit = CapturedXcodeProject(
    name: "explicit", file: "tree/ios/KaMPKitiOS.xcodeproj/project.pbxproj",
    projectPath: "ios/KaMPKitiOS.xcodeproj")
  static let xcodegen = CapturedXcodeProject(
    name: "xcodegen", file: "tree/Tests/Fixtures/SPM/SPM.xcodeproj/project.pbxproj",
    projectPath: "Tests/Fixtures/SPM/SPM.xcodeproj")
  /// Tuist's project is ignored by the repository, so the capture keeps the generated one.
  static let tuist = CapturedXcodeProject(
    name: "tuist", file: "generated/App.xcodeproj/project.pbxproj",
    projectPath: "examples/xcode/generated_app_with_framework_and_tests/App.xcodeproj")

  static let all = [synchronized, explicit, xcodegen, tuist]

  func text() throws -> String { try Fixture.text("Xcode/\(name)/\(file)") }

  func project() throws -> PBXProject { try PBXProject(parsing: text()) }

  func membership() throws -> TargetMembership {
    TargetMembership(project: try project(), projectPath: projectPath)
  }

  /// The case's `git ls-files`, so a test's path can't be a typo that answers "no target".
  func trackedPaths() throws -> Set<String> {
    Set(try Fixture.text("Xcode/\(name)/ls-files.txt").split(separator: "\n").map(String.init))
  }
}

@Suite("a project.pbxproj parses into its objects")
struct PBXProjectTests {
  @Test(
    "each captured project names its native targets in order with their product types — catches targets dropped or read from the wrong key",
    arguments: [
      (
        CapturedXcodeProject.synchronized,
        [
          "Buy:framework", "Buy tvOS:framework", "Buy watchOS:framework",
          "BuyTests:bundle.unit-test",
        ]
      ),
      (
        CapturedXcodeProject.explicit,
        [
          "KaMPKitiOS:application", "KaMPKitiOSTests:bundle.unit-test",
          "KaMPKitiOSUITests:bundle.ui-testing",
        ]
      ),
      (
        CapturedXcodeProject.xcodegen,
        ["App:application", "StaticLibrary:library.static", "Tests:bundle.unit-test"]
      ),
      (
        CapturedXcodeProject.tuist,
        [
          "App:application", "AppExtension:app-extension", "AppTests:bundle.unit-test",
          "Framework:framework", "FrameworkTests:bundle.unit-test",
        ]
      ),
    ])
  func targetsInOrder(fixture: CapturedXcodeProject, expected: [String]) throws {
    let targets = try fixture.project().nativeTargets
    let prefix = "com.apple.product-type."
    #expect(
      targets.map {
        "\($0.name):\(($0.productType ?? "").replacingOccurrences(of: prefix, with: ""))"
      }
        == expected)
  }

  @Test(
    "test bundles are test targets and apps and frameworks are not — catches a UI test bundle read as app code"
  )
  func testTargets() throws {
    let targets = try CapturedXcodeProject.explicit.project().nativeTargets
    #expect(targets.map(\.isTest) == [false, true, true])
  }

  @Test(
    "a Sources phase lists its build files' file references and a package product adds none — catches build files read as file references"
  )
  func sourcesPhase() throws {
    let project = try CapturedXcodeProject.xcodegen.project()
    let app = try #require(project.nativeTargets.first { $0.name == "App" })
    let sources = try #require(app.buildPhases.first { $0.isSources })
    #expect(sources.fileReferenceIDs == ["26F7EFEE613987D1E1258A60"])
    let frameworks = try #require(app.buildPhases.first { $0.isa == "PBXFrameworksBuildPhase" })
    #expect(frameworks.fileReferenceIDs == ["CAB5625F6FEA668410ED5482"])
  }

  @Test(
    "a synchronized folder carries each target's exception set by target id — catches exception sets left unread"
  )
  func synchronizedExceptions() throws {
    let project = try CapturedXcodeProject.synchronized.project()
    let groups = project.synchronizedRootGroups
    #expect(groups.map(\.id) == ["4E697FC12E1D5E0A00329950", "4E6984B62E1D5E4500329950"])
    let buy = try #require(groups.first)
    #expect(
      buy.exceptions.map(\.targetID) == [
        "9AEF60F21E5F42D90067FA90", "9AF255B11F6FEE50005BB0C9", "9AC2EF371F6818180037E0D7",
      ])
    #expect(buy.exceptions.allSatisfy { $0.membershipExceptions == ["Info.plist"] })
    let framework = try #require(project.nativeTargets.first { $0.name == "Buy" })
    #expect(framework.synchronizedGroupIDs == ["4E697FC12E1D5E0A00329950"])
  }

  @Test(
    "quoted strings decode their escapes and comments never become values — catches escapes kept raw"
  )
  func quotedStrings() throws {
    let project = try CapturedXcodeProject.explicit.project()
    let script = try #require(
      project.objects.values.first { $0.isa == "PBXShellScriptBuildPhase" })
    #expect(script.string("shellScript")?.contains("cd \"$SRCROOT/..\"\n./gradlew") == true)
    let mainGroup = try #require(project.mainGroupID.flatMap { project.objects[$0] })
    #expect(mainGroup.strings("children").first == "F1465EFF23AA94BF0055F7C3")
  }

  @Test(
    "a project cut off halfway fails to parse instead of yielding the objects before the cut — catches a partial project read as whole"
  )
  func damagedProject() throws {
    let text = try Fixture.text("Xcode/explicit/damaged/KaMPKitiOS.xcodeproj/project.pbxproj")
    #expect(throws: PBXProjectError.self) { try PBXProject(parsing: text) }
  }

  @Test(
    "a project whose root object is missing fails naming it — catches an empty project read as valid"
  )
  func missingRoot() throws {
    let text = try CapturedXcodeProject.tuist.text()
    let root = "rootObject = "
    let start = try #require(text.range(of: root))
    let renamed = text.replacingCharacters(
      in: start.upperBound..<text.index(start.upperBound, offsetBy: 24),
      with: "000000000000000000000000")
    #expect(throws: PBXProjectError.missingObject("000000000000000000000000")) {
      try PBXProject(parsing: renamed)
    }
  }
}
