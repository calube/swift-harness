import SwiftGateDomain
import Testing

@Suite("Config")
struct ConfigTests {
  @Test("building a Config in code enforces the same rules as the file — catches a bypass path")
  func initEnforcesInvariants() {
    #expect {
      _ = try Config(
        xcode: "26.2", appScheme: "App", packages: ["Packages/*"],
        simulator: SimulatorConfig(device: "iPhone 17", os: "26.2"),
        pyramid: PyramidConfig(maxFlows: 0),
        flows: [Flow(name: "checkout", reason: "revenue")],
        modules: [ModuleOverride(name: "Engine", kind: .engine, reason: nil)])
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .tooManyFlows(count: 1, max: 0),
        .missingReason(path: "modules[0].reason", module: "Engine", rule: .nonDefaultKind(.engine)),
      ]
    }
  }

  @Test("schema reports a non-table document instead of trapping — catches crash on bad input")
  func nonTableDocument() {
    #expect {
      _ = try ConfigSchema.config(from: .string("x"))
    } throws: { error in
      (error as? ConfigValidationError)?.issues == [
        .wrongType(path: "(root)", expected: "table", found: "string")
      ]
    }
  }
}
