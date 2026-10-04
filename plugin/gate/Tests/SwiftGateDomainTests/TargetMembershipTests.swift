import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("target membership answers which targets build a path")
struct TargetMembershipTests {
  @Test(
    "each captured project answers 3 tracked files with the targets that compile them — catches a parser that only reads explicit lists",
    arguments: [
      (
        CapturedXcodeProject.synchronized,
        [
          "Buy/Client/Graph.Cache.swift": ["Buy", "Buy tvOS", "Buy watchOS"],
          "BuyTests/Client/Graph.ClientTests.swift": ["BuyTests"],
          "Package.swift": [],
        ]
      ),
      (
        CapturedXcodeProject.explicit,
        [
          "ios/KaMPKitiOS/AppDelegate.swift": ["KaMPKitiOS"],
          "ios/KaMPKitiOSTests/KaMPKitiOSTests.swift": ["KaMPKitiOSTests"],
          "ios/KaMPKitiOSUITests/KaMPKitiOSUITests.swift": ["KaMPKitiOSUITests"],
        ]
      ),
      (
        CapturedXcodeProject.xcodegen,
        [
          "Tests/Fixtures/SPM/SPM/AppDelegate.swift": ["App"],
          "Tests/Fixtures/SPM/StaticLibrary/StaticLibrary.swift": ["StaticLibrary"],
          "Tests/Fixtures/SPM/FooFeature/Sources/FooDomain/FooDomain.swift": [],
        ]
      ),
      (
        CapturedXcodeProject.tuist,
        [
          "examples/xcode/generated_app_with_framework_and_tests/App/AppDelegate.swift": ["App"],
          "examples/xcode/generated_app_with_framework_and_tests/AppExtension/Extension.swift": [
            "AppExtension"
          ],
          "examples/xcode/generated_app_with_framework_and_tests/FrameworkTests/FrameworkTests.swift":
            ["FrameworkTests"],
        ]
      ),
    ])
  func compiledFiles(fixture: CapturedXcodeProject, expected: [String: [String]]) throws {
    let membership = try fixture.membership()
    let tracked = try fixture.trackedPaths()
    for (path, targets) in expected {
      #expect(tracked.contains(path), "\(path) isn't tracked in \(fixture.name)")
      #expect(membership.targets(compiling: path).map(\.name) == targets, "\(path)")
    }
  }

  @Test(
    "a file a synchronized folder's exception set names belongs to none of the folder's targets — catches exceptions ignored"
  )
  func synchronizedExceptionExcludes() throws {
    let membership = try CapturedXcodeProject.synchronized.membership()
    #expect(membership.targets(including: "Buy/Info.plist").isEmpty)
    #expect(membership.targets(including: "BuyTests/Info.plist").isEmpty)
    #expect(
      membership.targets(including: "Buy/Buy.h").map(\.name) == ["Buy", "Buy tvOS", "Buy watchOS"])
  }

  @Test(
    "a resource an explicit project copies is included but not compiled, and a file no phase holds is in no target — catches every build phase read as compiling, and a localized group read as its whole folder"
  )
  func resourcesAreNotCompiled() throws {
    let membership = try CapturedXcodeProject.explicit.membership()
    let path = "ios/KaMPKitiOS/Base.lproj/Main.storyboard"
    #expect(try CapturedXcodeProject.explicit.trackedPaths().contains(path))
    #expect(membership.targets(compiling: path).isEmpty)
    #expect(membership.targets(including: path).map(\.name) == ["KaMPKitiOS"])
    #expect(membership.targets(including: "ios/KaMPKitiOS/Info.plist").isEmpty)
  }

  @Test(
    "source roots are the folders of compiled files and synchronized folders, never a folder reference to the repository — catches every group folder counted as a source root"
  )
  func sourceRoots() throws {
    #expect(
      try CapturedXcodeProject.xcodegen.membership().sourceRoots.sorted() == [
        "Tests/Fixtures/SPM/SPM", "Tests/Fixtures/SPM/SPMTests",
        "Tests/Fixtures/SPM/StaticLibrary",
      ])
    #expect(
      try CapturedXcodeProject.synchronized.membership().sourceRoots.sorted() == [
        "Buy", "BuyTests",
      ])
  }

  @Test(
    "a new Swift file under an explicit project's source root that no target compiles is a major finding naming the add-file helper — catches a new file left out of every target"
  )
  func explicitNewFileIsAFinding() throws {
    let findings = try CapturedXcodeProject.explicit.membership().newFileFindings(
      ["ios/KaMPKitiOS/NewScreen.swift", "ios/KaMPKitiOSTests/NewTests.swift"],
      inclusion: .explicit)
    #expect(
      findings.map(\.file) == [
        "ios/KaMPKitiOS/NewScreen.swift", "ios/KaMPKitiOSTests/NewTests.swift",
      ])
    #expect(findings.allSatisfy { $0.ruleID == BrownfieldRuleID.fileNotInTarget.rawValue })
    #expect(findings.allSatisfy { $0.severity == .major && $0.line == nil })
    #expect(findings.first?.message.contains("swiftgate xcode add-file") == true)
    #expect(findings.first?.message.contains("KaMPKitiOS.xcodeproj") == true)
  }

  @Test(
    "a new file in a synchronized test target's folder is compiled by it and is not a finding — catches synchronized folders read as empty"
  )
  func synchronizedNewFileJoins() throws {
    let membership = try CapturedXcodeProject.synchronized.membership()
    let path = "BuyTests/Client/NewTests.swift"
    #expect(membership.targets(compiling: path).map(\.name) == ["BuyTests"])
    #expect(try membership.newFileFindings([path], inclusion: .synchronized).isEmpty)
  }

  @Test(
    "a new Swift file outside every source root, or a new file that isn't Swift, is not a finding — catches files the project doesn't own flagged"
  )
  func outsideSourceRoots() throws {
    let explicit = try CapturedXcodeProject.explicit.membership().newFileFindings(
      ["ios/Tooling.swift", "ios/KaMPKitiOS/notes.md", "shared/src/Model.swift"],
      inclusion: .explicit)
    #expect(explicit.isEmpty)
    let xcodegen = try CapturedXcodeProject.xcodegen.membership().newFileFindings(
      ["Tests/Fixtures/SPM/FooFeature/Sources/FooDomain/Added.swift"], inclusion: .xcodegen)
    #expect(xcodegen.isEmpty)
  }

  @Test(
    "a generated project's finding names its generator instead of the add-file helper — catches a remedy that edits a generated project by hand"
  )
  func generatedRemedy() throws {
    let xcodegen = try CapturedXcodeProject.xcodegen.membership().newFileFindings(
      ["Tests/Fixtures/SPM/SPM/Added.swift"], inclusion: .xcodegen)
    #expect(xcodegen.map(\.file) == ["Tests/Fixtures/SPM/SPM/Added.swift"])
    #expect(xcodegen.first?.message.contains("xcodegen generate") == true)
    #expect(xcodegen.first?.message.contains("add-file") == false)
    let tuist = try CapturedXcodeProject.tuist.membership().newFileFindings(
      ["examples/xcode/generated_app_with_framework_and_tests/AppTests/Added.swift"],
      inclusion: .tuist)
    #expect(tuist.first?.message.contains("tuist generate") == true)
  }

  @Test(
    "an exception set naming a target that doesn't own the folder adds those files to that target — catches inclusions read as exclusions"
  )
  func exceptionAddsForNonOwner() throws {
    let text = try CapturedXcodeProject.synchronized.text()
    let owner =
      "fileSystemSynchronizedGroups = (\n\t\t\t\t4E697FC12E1D5E0A00329950 /* Buy */,\n\t\t\t);\n\t\t\tname = \"Buy watchOS\";"
    #expect(text.contains(owner))
    let detached = text.replacing(
      owner, with: "fileSystemSynchronizedGroups = (\n\t\t\t);\n\t\t\tname = \"Buy watchOS\";")
    let membership = TargetMembership(
      project: try PBXProject(parsing: detached), projectPath: "Buy.xcodeproj")
    #expect(membership.targets(including: "Buy/Info.plist").map(\.name) == ["Buy watchOS"])
    #expect(
      membership.targets(compiling: "Buy/Client/Graph.Cache.swift").map(\.name) == [
        "Buy", "Buy tvOS",
      ])
    #expect(membership.targets(compiling: "Buy/Makefile").isEmpty)
  }

  @Test(
    "a new Swift file every owner of a synchronized folder leaves out is a finding naming the exception — catches excluded files counted as compiled"
  )
  func synchronizedExcludedNewFile() throws {
    let text = try CapturedXcodeProject.synchronized.text()
    let list = "membershipExceptions = (\n\t\t\t\tInfo.plist,"
    #expect(text.contains(list))
    let excluded = text.replacing(list, with: list + "\n\t\t\t\tLegacy.swift,")
    let membership = TargetMembership(
      project: try PBXProject(parsing: excluded), projectPath: "Buy.xcodeproj")
    let findings = try membership.newFileFindings(["Buy/Legacy.swift"], inclusion: .synchronized)
    #expect(findings.map(\.file) == ["Buy/Legacy.swift"])
    #expect(findings.first?.message.contains("exception") == true)
  }
}
