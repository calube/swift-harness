import Foundation
import SwiftGateDomain
import SwiftGateRules
import Testing

/// A text input whose title is only a placeholder: the captured contract view and the shapes
/// around it.
@Suite("a11y.input-label")
struct InputLabelRuleTests {
  static let ruleID = "a11y.input-label"
  static let path = "Packages/AppFeature/Sources/AppUI/DetailView.swift"

  static func fixture(_ variant: String) throws -> String {
    try String(
      contentsOf: URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/rules/\(ruleID)/\(variant)/DetailView.swift"),
      encoding: .utf8)
  }

  static func lines(_ body: String) throws -> [Int] {
    let text = "import SwiftUI\n\nstruct Screen: View {\n  var body: some View {\n\(body)\n  }\n}\n"
    let rule = try #require(RuleCatalog.lint.first { $0.descriptor.id == ruleID })
    return try RuleEngine(rules: [rule]).run(
      [SourceInput(path: "Sources/AppUI/Screen.swift", text: text)],
      context: RuleContext(scopes: StaticModuleScopes())
    ).findings.compactMap(\.line)
  }

  static func file(_ text: String, added: [ClosedRange<Int>]? = nil) -> ChangedTestFile {
    let count = text.split(separator: "\n", omittingEmptySubsequences: false).count
    return ChangedTestFile(
      path: path, content: text, added: AddedLines(path: path, ranges: added ?? [1...count]))
  }

  @Test(
    "a SecureField and a TextEditor with an identifier and no label fire at the field, however long the chain between them — catches the rule matching only TextField or only a modifier right after it"
  )
  func everyInputKindFires() throws {
    let found = try Self.lines(
      """
          VStack {
            SecureField("Password", text: .constant(""))
              .textContentType(.password)
              .padding()
              .accessibilityIdentifier("signIn.password")
            TextEditor(text: .constant(""))
              .accessibilityIdentifier("signIn.bio")
            Text("Bio").accessibilityLabel("Bio")
          }
      """)
    #expect(found == [6, 10])
  }

  @Test(
    "a label on the field's own chain, on a container holding it, or a LabeledContent around it clears the field, while a label on a sibling does not — catches a false positive on a labeled field or a sibling's label hiding one"
  )
  func labelsClearOnlyTheirOwnField() throws {
    let found = try Self.lines(
      """
          VStack {
            TextField("Name", text: .constant("")).accessibilityIdentifier("a.name").accessibilityLabel("Name")
            LabeledContent("City") { TextField("City", text: .constant("")).accessibilityIdentifier("a.city") }
            Group { TextField("Zip", text: .constant("")).accessibilityIdentifier("a.zip") }.accessibilityLabel("Zip")
            TextField("Street", text: .constant("")).accessibilityIdentifier("a.street")
            Text("Street").accessibilityLabel("Street")
          }
      """)
    #expect(found == [9])
  }

  @Test(
    "a field carrying a same-line `swiftgate:allow a11y.input-label — <reason>` is waived — catches a field the author labeled another way having no escape"
  )
  func sameLineAllowWaives() throws {
    let found = try Self.lines(
      """
          TextField("Code", text: .constant("")).accessibilityIdentifier("a.code") // swiftgate:allow a11y.input-label — the UIKit wrapper sets the label
      """)
    #expect(found.isEmpty)
  }

  @Test(
    "the captured contract view, new in the change, is RED at its draft field with file and line, and the fixer's labeled version is clean — catches a slice gate passing the field sim.a11y-label later failed every flow row on"
  )
  func capturedFieldFiresInChangedFiles() throws {
    let found = ChangedInputLabels.findings([Self.file(try Self.fixture("bad"))])
    #expect(found.map(\.ruleID) == [ChangedInputLabels.ruleID])
    #expect(found.map(\.file) == [Self.path])
    #expect(found.map(\.line) == [46])
    #expect(found.allSatisfy { $0.severity.failsGate })

    let fixed = ChangedInputLabels.findings([Self.file(try Self.fixture("good"))])
    #expect(fixed.isEmpty, "\(fixed.map(\.message))")
  }

  @Test(
    "a change that leaves the unlabeled field's lines alone doesn't gate on it, and a change to its identifier line does — catches an old field failing every task that edits its file"
  )
  func onlyAddedFieldsGate() throws {
    let text = try Self.fixture("bad")
    #expect(ChangedInputLabels.findings([Self.file(text, added: [1...40])]).isEmpty)
    #expect(ChangedInputLabels.findings([Self.file(text, added: [47...47])]).map(\.line) == [47])
  }
}
