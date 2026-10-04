import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

@Suite("a source file joins an explicit project's target by inserted lines")
struct PBXProjectEditTests {
  static let fixture = CapturedXcodeProject.explicit
  static let newFile = "ios/KaMPKitiOS/BreedDetailScreen.swift"

  static func add(
    _ path: String = newFile, target: String = "KaMPKitiOS", to text: String? = nil,
    fixture: CapturedXcodeProject = fixture
  ) throws -> PBXAddFileResult {
    try PBXProjectEdit.addFile(
      path, target: target, projectPath: fixture.projectPath, to: text ?? fixture.text())
  }

  static func added(_ result: PBXAddFileResult) throws -> (PBXAddedFile, String) {
    guard case .added(let added, let text) = result else {
      Issue.record("expected an add, got \(result)")
      throw CancellationError()
    }
    return (added, text)
  }

  /// The lines of `edited` that `original` lacks, in order; `original` must be `edited` without them.
  static func insertedLines(_ original: String, _ edited: String) -> [String] {
    var originalLines = original.split(separator: "\n", omittingEmptySubsequences: false)[...]
    var inserted: [String] = []
    for line in edited.split(separator: "\n", omittingEmptySubsequences: false) {
      if originalLines.first == line {
        originalLines.removeFirst()
      } else {
        inserted.append(String(line))
      }
    }
    #expect(originalLines.isEmpty, "edited text dropped original lines: \(originalLines.prefix(3))")
    return inserted
  }

  @Test(
    "adding a file makes the target compile it while every original line stays byte for byte — catches a rewrite of the whole file"
  )
  func addKeepsEveryOtherByte() throws {
    let original = try Self.fixture.text()
    let (added, edited) = try Self.added(try Self.add())

    let membership = TargetMembership(
      project: try PBXProject(parsing: edited), projectPath: Self.fixture.projectPath)
    #expect(membership.targets(compiling: Self.newFile).map(\.name) == ["KaMPKitiOS"])
    let inserted = Self.insertedLines(original, edited)
    #expect(
      inserted == [
        "\t\t\(added.buildFileID) /* BreedDetailScreen.swift in Sources */ = {isa = PBXBuildFile; fileRef = \(added.fileReferenceID) /* BreedDetailScreen.swift */; };",
        "\t\t\(added.fileReferenceID) /* BreedDetailScreen.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = BreedDetailScreen.swift; sourceTree = \"<group>\"; };",
        "\t\t\t\t\(added.fileReferenceID) /* BreedDetailScreen.swift */,",
        "\t\t\t\t\(added.buildFileID) /* BreedDetailScreen.swift in Sources */,",
      ])
    #expect(added.groupID == "F1465EFF23AA94BF0055F7C3")
    #expect(added.sourcesPhaseID == "F1465EF923AA94BF0055F7C3")
  }

  @Test(
    "new objects land in their sections in id order — catches entries appended where Xcode wouldn't write them"
  )
  func sectionsStaySorted() throws {
    let (_, edited) = try Self.added(try Self.add())
    for section in ["PBXBuildFile", "PBXFileReference"] {
      let body = try #require(
        edited.components(separatedBy: "/* Begin \(section) section */\n").last?
          .components(separatedBy: "/* End \(section) section */").first)
      let ids = body.split(separator: "\n").map { String($0.dropFirst(2).prefix(24)) }
      #expect(ids == ids.sorted(), "\(section)")
      #expect(ids.count == (section == "PBXBuildFile" ? 9 : 15))
    }
  }

  @Test(
    "adding the same file to the same target twice changes nothing the second time — catches a duplicate build file"
  )
  func secondAddIsNoOp() throws {
    let (_, edited) = try Self.added(try Self.add())
    #expect(try Self.add(to: edited) == .alreadyCompiled)
  }

  @Test(
    "the ids are the same on 2 runs and differ per target — catches random or time-based ids"
  )
  func stableIDs() throws {
    let (first, firstText) = try Self.added(try Self.add())
    let (second, secondText) = try Self.added(try Self.add())
    #expect(first == second)
    #expect(firstText == secondText)
    let hex = Set("0123456789ABCDEF")
    for id in [first.fileReferenceID, first.buildFileID] {
      #expect(id.count == 24 && id.allSatisfy(hex.contains), "\(id)")
    }
    #expect(first.fileReferenceID != first.buildFileID)
    #expect(
      PBXProjectEdit.stableID("buildFile", path: Self.newFile, target: "KaMPKitiOSTests")
        != first.buildFileID)
    #expect(
      PBXProjectEdit.stableID("buildFile", path: Self.newFile, target: "KaMPKitiOS")
        == first.buildFileID)
  }

  @Test(
    "a file another target already compiles keeps its file reference and gains only a build file — catches a second reference to 1 file"
  )
  func reusesReference() throws {
    let original = try Self.fixture.text()
    let (added, edited) = try Self.added(
      try Self.add("ios/KaMPKitiOS/Koin.swift", target: "KaMPKitiOSTests"))
    #expect(added.fileReferenceID == "46B5284C249C5CF400A7725D")
    #expect(added.groupID == nil)
    #expect(Self.insertedLines(original, edited).count == 2)
    let membership = TargetMembership(
      project: try PBXProject(parsing: edited), projectPath: Self.fixture.projectPath)
    #expect(
      membership.targets(compiling: "ios/KaMPKitiOS/Koin.swift").map(\.name) == [
        "KaMPKitiOS", "KaMPKitiOSTests",
      ])
  }

  @Test(
    "a file in a folder no group names joins the nearest group with a relative path and a name — catches a new group or a wrong path"
  )
  func nestedFolder() throws {
    let path = "ios/KaMPKitiOS/Breeds/BreedRow.swift"
    let (added, edited) = try Self.added(try Self.add(path))
    #expect(added.groupID == "F1465EFF23AA94BF0055F7C3")
    #expect(edited.contains("name = BreedRow.swift; path = Breeds/BreedRow.swift;"))
    let project = try PBXProject(parsing: edited)
    #expect(project.objects.values.filter { $0.isa == "PBXGroup" }.count == 6)
    let membership = TargetMembership(project: project, projectPath: Self.fixture.projectPath)
    #expect(membership.targets(compiling: path).map(\.name) == ["KaMPKitiOS"])
  }

  @Test(
    "an unknown target, a header and a path outside every group are refused by name — catches an add to the wrong place",
    arguments: [
      (
        newFile, "Widget",
        PBXProjectEditError.targetNotFound(
          "Widget", known: ["KaMPKitiOS", "KaMPKitiOSTests", "KaMPKitiOSUITests"])
      ),
      ("ios/KaMPKitiOS/Bridge.h", "KaMPKitiOS", .notASourceFile("ios/KaMPKitiOS/Bridge.h")),
      ("shared/Greeting.swift", "KaMPKitiOS", .outsideProject("shared/Greeting.swift")),
    ])
  func refusals(path: String, target: String, expected: PBXProjectEditError) throws {
    #expect(throws: expected) { try Self.add(path, target: target) }
  }

  @Test(
    "a file under a target's synchronized folder needs no edit, and only for a target the project has — catches an explicit entry beside the folder"
  )
  func synchronizedFolder() throws {
    #expect(
      try Self.add("Buy/Client/NewCache.swift", target: "Buy", fixture: .synchronized)
        == .alreadyCompiled)
    #expect(
      throws: PBXProjectEditError.targetNotFound(
        "Buy macOS", known: ["Buy", "Buy tvOS", "Buy watchOS", "BuyTests"])
    ) { try Self.add("Buy/Client/NewCache.swift", target: "Buy macOS", fixture: .synchronized) }
  }

  @Test(
    "a damaged project is refused before any edit — catches an edit over a half-read file")
  func damaged() throws {
    let text = try Fixture.text("Xcode/explicit/damaged/KaMPKitiOS.xcodeproj/project.pbxproj")
    #expect(throws: PBXProjectEditError.self) { try Self.add(to: text) }
  }

  @Test(
    "a name with a space is quoted the way the parser reads it back — catches a bare path that splits the project"
  )
  func quotedName() throws {
    let path = "ios/KaMPKitiOS/Breed Row.swift"
    let (_, edited) = try Self.added(try Self.add(path))
    #expect(edited.contains("path = \"Breed Row.swift\"; sourceTree"))
    let membership = TargetMembership(
      project: try PBXProject(parsing: edited), projectPath: Self.fixture.projectPath)
    #expect(membership.targets(compiling: path).map(\.name) == ["KaMPKitiOS"])
  }

  @Test(
    "a project with no build file section gains 1 between its neighbours in name order — catches a build file written outside any section"
  )
  func missingSection() throws {
    let text = try Self.fixture.text()
    let begin = try #require(text.range(of: "/* Begin PBXBuildFile section */\n"))
    let end = try #require(text.range(of: "/* End PBXBuildFile section */\n\n"))
    let stripped = text.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: "")
    let (added, edited) = try Self.added(try Self.add(to: stripped))
    #expect(
      edited.contains(
        "/* Begin PBXBuildFile section */\n\t\t\(added.buildFileID) /* BreedDetailScreen.swift in Sources */"
      ))
    let section = try #require(edited.range(of: "/* End PBXBuildFile section */\n\n"))
    #expect(edited[section.upperBound...].hasPrefix("/* Begin PBXContainerItemProxy section */"))
  }

  @Test(
    "an id the project already uses is never reused for a new object — catches 2 objects under 1 id"
  )
  func idCollision() throws {
    let taken = PBXProjectEdit.stableID(
      "fileReference", path: Self.newFile, target: "KaMPKitiOS")
    let text = try Self.fixture.text().replacing("6278498AD96A4D949D39BF44", with: taken)
    let (added, edited) = try Self.added(try Self.add(to: text))
    #expect(added.fileReferenceID != taken)
    #expect(try PBXProject(parsing: edited).objects[taken]?.isa == "PBXGroup")
  }

  @Test(
    "a target with no Sources phase, or a phase whose files sit on 1 line, is refused without an edit — catches a phase created or a line rewritten"
  )
  func layoutRefusals() throws {
    let text = try Self.fixture.text()
    let noPhase = text.replacing("\t\t\t\tF1465EF923AA94BF0055F7C3 /* Sources */,\n", with: "")
    #expect(throws: PBXProjectEditError.noSourcesPhase(target: "KaMPKitiOS")) {
      try Self.add(to: noPhase)
    }
    let oneLine = text.replacing(
      "files = (\n\t\t\t\tF1465F1823AA94C00055F7C3 /* KaMPKitiOSTests.swift in Sources */,\n\t\t\t);",
      with: "files = (F1465F1823AA94C00055F7C3 /* KaMPKitiOSTests.swift in Sources */, );")
    #expect(oneLine != text)
    #expect(
      throws: PBXProjectEditError.unrecognizedLayout(
        "F1465F0F23AA94C00055F7C3 has no multi-line files")
    ) { try Self.add("ios/KaMPKitiOSTests/More.swift", target: "KaMPKitiOSTests", to: oneLine) }
  }

}
