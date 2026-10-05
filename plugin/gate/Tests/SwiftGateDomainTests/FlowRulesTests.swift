import Foundation
import SwiftGateDomain
import SwiftGateTestSupport
import Testing

/// The 5 batch steps file rules, checked against the pinned tool's captured schemas and the ids
/// SampleApp declares.
@Suite("flow rules")
struct FlowRulesTests {
  /// The captured `tools/list` schemas the plugin ships.
  static func schemas() throws -> ToolSchemas {
    let folder = Fixture.checkoutRoot.appending(path: "qa", directoryHint: .isDirectory)
    let file = try #require(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).first {
        $0.hasPrefix("agent-device-schemas-") && $0.hasSuffix(".json")
      })
    return try ToolSchemas.parse(Data(contentsOf: folder.appending(path: file)))
  }

  static let sampleIDs = FlowIDs.declared(
    source: "Packages/AccessibilityIDs/Sources/AccessibilityIDs/AccessibilityID.swift",
    ids: [
      "counter.value", "counter.increment", "counter.decrement", "counter.fact",
      "counter.factText",
    ])

  static func check(_ name: String, ids: FlowIDs = sampleIDs) throws -> [Finding] {
    FlowRules.check(
      file: "qa/\(name)", data: try Fixture.data("QA/\(name)"), schemas: try schemas(), ids: ids)
  }

  static func check(json: String, ids: FlowIDs = sampleIDs) throws -> [Finding] {
    FlowRules.check(
      file: "qa/inline.flow.json", data: Data(json.utf8), schemas: try schemas(), ids: ids)
  }

  @Test(
    "the SampleApp counter flow, the steps the pinned tool ran green, passes all 5 rules — catches a rule that fires on a working flow"
  )
  func counterFlowPasses() throws {
    let schemas = try Self.schemas()

    #expect(try Self.check("counter.flow.json") == [])
    #expect(schemas.version == "0.21.18")
    #expect(["wait", "press", "is", "snapshot"].allSatisfy { schemas.commands[$0] != nil })
  }

  @Test(
    "a typo'd id fails qa.flow-unknown-id naming the id and the module — catches the typo the Swift compiler let through"
  )
  func typoID() throws {
    let findings = try Self.check("typo-id.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.unknownIDRuleID])
    let finding = try #require(findings.first)
    #expect(finding.severity == .major)
    #expect(finding.file == "qa/typo-id.flow.json")
    #expect(finding.message.contains("counter.incremnet"))
    #expect(finding.message.contains("step 2"))
    #expect(finding.message.contains("AccessibilityID.swift"))
  }

  @Test(
    "a misspelt input key fails qa.flow-schema naming the command and the key — catches a step the device would refuse only after booting"
  )
  func misspeltKey() throws {
    let findings = try Self.check("misspelt-key.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.schemaRuleID])
    let message = try #require(findings.first?.message)
    #expect(message.contains("step 1"))
    #expect(message.contains("`wait`"))
    #expect(message.contains("selecter"))
    #expect(findings.first?.severity == .major)
  }

  @Test(
    "the steps the pinned tool refused as INVALID_ARGS fail qa.flow-schema at `target` — catches a schema check looser than the tool"
  )
  func toolRefusedStepsFailSchema() throws {
    let findings = try Self.check("target-object.flow.json")

    #expect(findings.map(\.ruleID).contains(FlowRules.schemaRuleID))
    let schema = findings.filter { $0.ruleID == FlowRules.schemaRuleID }
    #expect(schema.contains { $0.message.contains("step 1") && $0.message.contains("target") })
    #expect(!findings.map(\.ruleID).contains(FlowRules.unparsedRuleID))
  }

  @Test(
    "a flow whose only read is `get` fails qa.flow-no-assert — catches a flow that reads a value and proves nothing"
  )
  func getOnly() throws {
    let findings = try Self.check("get-only.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.noAssertRuleID])
    #expect(findings.first?.severity == .major)
  }

  @Test(
    "a flow whose only wait is a duration fails qa.flow-no-assert — catches a sleep counted as a check"
  )
  func durationWaitOnly() throws {
    #expect(
      try Self.check("wait-duration-only.flow.json").map(\.ruleID) == [FlowRules.noAssertRuleID])
  }

  @Test(
    "a wait for text or an absent selector counts as the assertion — catches a no-assert rule that only accepts selector waits"
  )
  func textAndAbsentWaitsAssert() throws {
    let text = try Self.check(
      json: #"[{"command":"wait","input":{"kind":"text","text":"Saved","timeoutMs":2000}}]"#)
    let absent = try Self.check(
      json: #"[{"command":"wait","input":{"kind":"absent","absent":"id=\"counter.fact\""}}]"#)
    let stable = try Self.check(
      json: #"[{"command":"wait","input":{"kind":"stable","stable":true}}]"#)

    #expect(text == [])
    #expect(absent == [])
    #expect(stable.map(\.ruleID) == [FlowRules.noAssertRuleID])
  }

  @Test(
    "a press on an @e ref fails qa.flow-ref-target naming the step — catches a flow bound to 1 snapshot's numbering"
  )
  func refTarget() throws {
    let findings = try Self.check("ref-target.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.refTargetRuleID])
    let message = try #require(findings.first?.message)
    #expect(message.contains("step 2"))
    #expect(message.contains("@e3"))
  }

  @Test(
    "a press on a point fails qa.flow-ref-target — catches a flow bound to 1 screen size"
  )
  func pointTarget() throws {
    let findings = try Self.check("point-target.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.refTargetRuleID])
    #expect(findings.first?.message.contains("step 2") == true)
  }

  @Test(
    "an @e ref in a selector string or a top-level x and y fails qa.flow-ref-target — catches refs and coordinates outside a target object"
  )
  func refsOutsideTargetObjects() throws {
    let selector = try Self.check(
      json: #"""
        [{"command":"wait","input":{"kind":"selector","selector":"@e7","timeoutMs":5000}},
         {"command":"is","input":{"predicate":"visible","selector":"id=\"counter.value\""}}]
        """#)
    let coordinates = try Self.check(
      json: #"""
        [{"command":"focus","input":{"x":10,"y":20}},
         {"command":"is","input":{"predicate":"visible","selector":"id=\"counter.value\""}}]
        """#)

    #expect(selector.map(\.ruleID) == [FlowRules.refTargetRuleID])
    #expect(coordinates.map(\.ruleID) == [FlowRules.refTargetRuleID])
  }

  @Test(
    "a step object that isn't in a list fails qa.flow-unparsed and nothing else — catches a later rule reporting noise on a file it can't read"
  )
  func notAList() throws {
    let findings = try Self.check("not-a-list.flow.json")

    #expect(findings.map(\.ruleID) == [FlowRules.unparsedRuleID])
    #expect(findings.first?.severity == .major)
  }

  @Test(
    "bytes that aren't JSON, a step without input, and a non-string command each fail qa.flow-unparsed naming why — catches a malformed step read as empty"
  )
  func unparsedShapes() throws {
    let notJSON = try Self.check(json: "[{\"command\": ")
    let noInput = try Self.check(
      json: #"[{"command":"wait","input":{"kind":"text","text":"a"}},{"command":"is"}]"#)
    let numberCommand = try Self.check(json: #"[{"command":3,"input":{}}]"#)

    #expect(notJSON.map(\.ruleID) == [FlowRules.unparsedRuleID])
    #expect(noInput.map(\.ruleID) == [FlowRules.unparsedRuleID])
    #expect(try #require(noInput.first).message.contains("step 2"))
    #expect(numberCommand.map(\.ruleID) == [FlowRules.unparsedRuleID])
  }

  @Test(
    "a command the pinned tool doesn't run in a batch fails qa.flow-schema naming it — catches an unknown command skipped as schema-free"
  )
  func unknownCommand() throws {
    let findings = try Self.check(
      json: #"""
        [{"command":"tapp","input":{}},
         {"command":"is","input":{"predicate":"visible","selector":"id=\"counter.value\""}}]
        """#)

    #expect(findings.map(\.ruleID) == [FlowRules.schemaRuleID])
    #expect(findings.first?.message.contains("tapp") == true)
  }

  @Test(
    "a missing required key and a wrong value type each fail qa.flow-schema naming the key — catches a check of key names alone"
  )
  func requiredAndType() throws {
    let missing = try Self.check(
      json: #"[{"command":"is","input":{"selector":"id=\"counter.value\""}}]"#)
    let wrongType = try Self.check(
      json: #"""
        [{"command":"wait","input":{"kind":"selector","selector":"id=\"counter.value\"","timeoutMs":"5s"}}]
        """#)

    #expect(missing.map(\.ruleID) == [FlowRules.schemaRuleID])
    #expect(missing.first?.message.contains("predicate") == true)
    #expect(wrongType.map(\.ruleID) == [FlowRules.schemaRuleID])
    #expect(wrongType.first?.message.contains("timeoutMs") == true)
  }

  @Test(
    "with no id module configured, a typo'd id passes and lint adds 1 non-gating qa.flow-ids-unknown note — catches ids reported unknown against nothing, or skipped silently"
  )
  func unconfiguredIDs() throws {
    let ids = FlowIDs.unconfigured(reason: "`[qa] accessibility_ids` is not set in .swiftgate.toml")
    let files = try ["typo-id.flow.json", "counter.flow.json"].map {
      (path: "qa/\($0)", data: try Fixture.data("QA/\($0)"))
    }

    let report = FlowRules.lint(files: files, schemas: try Self.schemas(), ids: ids)

    #expect(report.findings.map(\.ruleID) == [FlowRules.idsUnknownRuleID])
    let note = try #require(report.findings.first)
    #expect(note.severity == .nit)
    #expect(note.message.contains("accessibility_ids"))
    #expect(report.verdict == .green)
    #expect(report.files == ["qa/typo-id.flow.json", "qa/counter.flow.json"])
  }

  @Test(
    "lint over a clean and a broken file is RED with the broken file's findings — catches a verdict taken from the last file alone"
  )
  func lintVerdict() throws {
    let files = try ["get-only.flow.json", "counter.flow.json"].map {
      (path: "qa/\($0)", data: try Fixture.data("QA/\($0)"))
    }

    let report = FlowRules.lint(files: files, schemas: try Self.schemas(), ids: Self.sampleIDs)

    #expect(report.verdict == .red)
    #expect(report.findings.map(\.file) == ["qa/get-only.flow.json"])
  }
}

/// The JSON Schema subset the pinned tool's schemas use.
@Suite("flow schema")
struct FlowSchemaTests {
  static func schema(_ json: String) throws -> FlowSchema {
    try FlowSchema(json: try FlowJSON.parse(Data(json.utf8)), at: "")
  }

  @Test(
    "a keyword outside the supported set fails reading, naming the keyword and its place — catches a schema half-checked"
  )
  func unknownKeyword() throws {
    let error = #expect(throws: FlowSchemaError.self) {
      _ = try Self.schema(
        #"{"type":"object","properties":{"name":{"type":"string","pattern":"^a"}}}"#)
    }

    #expect(error?.reason.contains("pattern") == true)
    #expect(error?.path.contains("name") == true)
  }

  @Test(
    "enum, const, minimum, maximum, integer and oneOf each reject a value that breaks them — catches a keyword read but not checked"
  )
  func keywordsCheck() throws {
    let schema = try Self.schema(
      #"""
      {"type":"object","additionalProperties":false,"properties":{
        "mode":{"type":"string","enum":["a","b"]},
        "kind":{"const":"ref"},
        "count":{"type":"integer","minimum":1,"maximum":3},
        "target":{"oneOf":[{"type":"string"},{"type":"object","required":["x"]}]},
        "list":{"type":"array","items":{"type":"number"},"minItems":1,"maxItems":2},
        "not":{"not":{"required":["k"]}}
      }}
      """#)
    func violations(_ json: String) throws -> [String] {
      schema.violations(of: try FlowJSON.parse(Data(json.utf8)), at: "input")
    }

    #expect(try violations(#"{"mode":"a","kind":"ref","count":2,"target":"s","list":[1.5]}"#) == [])
    #expect(try violations(#"{"mode":"c"}"#).count == 1)
    #expect(try violations(#"{"kind":"point"}"#).count == 1)
    #expect(try violations(#"{"count":0}"#).count == 1)
    #expect(try violations(#"{"count":4}"#).count == 1)
    #expect(try violations(#"{"count":1.5}"#).count == 1)
    #expect(try violations(#"{"target":{}}"#).count == 1)
    #expect(try violations(#"{"list":[]}"#).count == 1)
    #expect(try violations(#"{"list":[1,2,3]}"#).count == 1)
    #expect(try violations(#"{"list":["a"]}"#).count == 1)
    #expect(try violations(#"{"not":{"k":1}}"#).count == 1)
    #expect(try violations(#"{"extra":true}"#).first?.contains("extra") == true)
  }

  @Test(
    "a whole number is an integer and a number, and true is neither — catches JSON booleans read as 1"
  )
  func numberKinds() throws {
    let integer = try Self.schema(#"{"type":"integer"}"#)
    let number = try Self.schema(#"{"type":"number"}"#)

    #expect(integer.violations(of: .integer(3), at: "v") == [])
    #expect(number.violations(of: .integer(3), at: "v") == [])
    #expect(integer.violations(of: try FlowJSON.parse(Data("true".utf8)), at: "v").count == 1)
    #expect(number.violations(of: try FlowJSON.parse(Data("true".utf8)), at: "v").count == 1)
  }
}
