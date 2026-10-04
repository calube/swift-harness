import Foundation
import SwiftGateDomain
import Testing

/// The tree under test is SampleApp's captured `agent-device snapshot --json`. Cases the capture
/// doesn't contain are made by editing one value of those captured bytes, so every other field
/// stays exactly as the runner printed it.
@Suite("simulator accessibility tree")
struct SimTreeTests {
  static let snapshot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/AgentDevice/snapshot.stdout")

  static func captured() throws -> String {
    try String(decoding: Data(contentsOf: snapshot), as: UTF8.self)
  }

  static func edited(_ original: String, to replacement: String) throws -> Data {
    let text = try captured()
    try #require(text.components(separatedBy: original).count == 2)
    return Data(text.replacingOccurrences(of: original, with: replacement).utf8)
  }

  @Test(
    "the captured SampleApp tree yields its 3 buttons under the application with their identifiers — catches a parser that drops child nodes"
  )
  func capturedButtons() throws {
    let tree = try SimTree.parse(snapshotJSON: Data(contentsOf: Self.snapshot))

    let root = try #require(tree.roots.only)
    #expect(root.role == .other)
    #expect(root.label == "SampleApp")
    #expect(root.children.count == 4)
    #expect(tree.elements.count == 5)
    #expect(!tree.isTruncated)

    let buttons = tree.elements.filter { $0.role == .button }
    #expect(
      buttons.map(\.identifier) == ["counter.decrement", "counter.increment", "counter.fact"])
    #expect(buttons.map(\.label) == ["Decrement", "Increment", "Cat fact"])
    #expect(buttons.allSatisfy { $0.isInteractive })
  }

  @Test(
    "an element without an identifier or value reads them as nil — catches an empty string standing in for a missing field"
  )
  func missingFieldsAreNil() throws {
    let tree = try SimTree.parse(snapshotJSON: Data(contentsOf: Self.snapshot))
    let root = try #require(tree.roots.only)
    #expect(root.identifier == nil)
    #expect(root.value == nil)
  }

  @Test("an element with an empty label parses to a nil label — catches \"\" read as a label")
  func emptyLabelIsNil() throws {
    let data = try Self.edited(#""label": "Cat fact""#, to: #""label": """#)
    let tree = try SimTree.parse(snapshotJSON: data)
    let fact = try #require(tree.elements.first { $0.identifier == "counter.fact" })
    #expect(fact.label == nil)
  }

  @Test(
    "a node type outside the role list fails parsing naming the type — catches an unknown role silently read as non-interactive"
  )
  func unknownRoleFails() throws {
    let data = try Self.edited(#""type": "StaticText""#, to: #""type": "Element(57)""#)
    #expect(throws: SimTreeError.unknownRole("Element(57)")) {
      try SimTree.parse(snapshotJSON: data)
    }
  }

  @Test(
    "a failure envelope is malformed, never an empty tree — catches an agent-device error read as a blank screen"
  )
  func failureEnvelopeIsMalformed() throws {
    let wait = Self.snapshot.deletingLastPathComponent().appending(path: "wait-text-absent.stdout")
    #expect {
      try SimTree.parse(snapshotJSON: Data(contentsOf: wait))
    } throws: { error in
      guard case .malformed = error as? SimTreeError else { return false }
      return true
    }
  }

  @Test(
    "contains(text:) finds the counter's text and not a word inside a label — catches substring matching"
  )
  func containsMatchesExactly() throws {
    let tree = try SimTree.parse(snapshotJSON: Data(contentsOf: Self.snapshot))
    #expect(tree.contains(text: "0"))
    #expect(tree.contains(text: "Cat fact"))
    #expect(!tree.contains(text: "Cat"))
    #expect(!tree.contains(text: "1"))
  }

  @Test(
    "exactly button, switch, text field and cell are interactive — catches a control role left out of the accessibility rules"
  )
  func interactiveRoles() {
    let interactive = SimElementRole.allCases.filter(\.isInteractive)
    #expect(Set(interactive) == [.button, .switch, .textField, .cell])
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}
