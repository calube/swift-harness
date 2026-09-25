import Foundation
import SwiftGateAdapters
import SwiftGateDomain
import Testing

@Suite("TOMLConfigDecoder")
struct TOMLConfigDecoderTests {
  let decoder = TOMLConfigDecoder()

  static let minimal = """
    schema = 1
    xcode = "26.2"
    app_scheme = "App"
    packages = ["Packages/*"]

    [simulator]
    device = "iPhone 17"
    os = "26.2"

    """

  func issues(_ toml: String) -> [ConfigIssue] {
    do {
      _ = try decoder.decode(toml)
      return []
    } catch {
      guard case .invalid(let validation) = error else { return [] }
      return validation.issues
    }
  }

  @Test("full valid config decodes every section — catches a key silently dropped by decoding")
  func fullValidConfig() throws {
    let config = try decoder.decode(
      """
      schema = 1
      xcode = "26.2"
      app_scheme = "App"
      packages = ["Packages/*", "Engine"]

      [simulator]
      device = "iPhone 17"
      os = "26.2"
      max_concurrent = 3

      [pyramid]
      diff_coverage_min = 0.85
      max_flows = 2

      [[flows]]
      name = "checkout"
      reason = "revenue-critical; crosses 3 features"

      [[flows]]
      name = "onboarding"
      reason = "first-run gate"

      [mutation]
      max_mutants = 40

      [budgets]
      t0 = 4
      t1 = 45
      t2 = 300
      stop_hook = 80

      [[modules]]
      name = "GameEngine"
      kind = "engine"
      reason = "60Hz fixed-timestep simulation; per-frame store overhead unjustified"

      [clients]
      vendor_modules = ["DatadogRUM", "FirebaseAnalytics"]

      [[modules]]
      name = "HealthCore"
      host_testable = false
      reason = "HealthKit types in public API; tests run on simulator"

      [judge]
      backend = "claude"
      advisory_threshold = 0.6
      block_threshold = 0.9
      """)

    let expected = try Config(
      xcode: "26.2", appScheme: "App", packages: ["Packages/*", "Engine"],
      simulator: SimulatorConfig(device: "iPhone 17", os: "26.2", maxConcurrent: 3),
      pyramid: PyramidConfig(diffCoverageMin: 0.85, maxFlows: 2),
      flows: [
        Flow(name: "checkout", reason: "revenue-critical; crosses 3 features"),
        Flow(name: "onboarding", reason: "first-run gate"),
      ],
      mutation: MutationConfig(maxMutants: 40),
      budgets: Budgets(
        t0: .seconds(4), t1: .seconds(45), t2: .seconds(300), t3: nil, stopHook: .seconds(80)),
      clients: ClientsConfig(vendorModules: ["DatadogRUM", "FirebaseAnalytics"]),
      modules: [
        ModuleOverride(
          name: "GameEngine", kind: .engine,
          reason: "60Hz fixed-timestep simulation; per-frame store overhead unjustified"),
        ModuleOverride(
          name: "HealthCore", hostTestable: false,
          reason: "HealthKit types in public API; tests run on simulator"),
      ],
      judge: .enabled(backend: .claude, thresholds: JudgeThresholds(advisory: 0.6, block: 0.9)))
    #expect(config == expected)
    #expect(config.kind(ofModule: "GameEngine") == .engine)
    #expect(config.kind(ofModule: "Checkout") == .feature)
    #expect(!config.isHostTestable(module: "HealthCore"))
  }

  @Test(
    "omitted optional sections take documented defaults — catches a missing section disabling a rule"
  )
  func defaults() throws {
    let config = try decoder.decode(Self.minimal)
    #expect(config.simulator.maxConcurrent == 2)
    #expect(config.pyramid == PyramidConfig(diffCoverageMin: 0.90, maxFlows: 10))
    #expect(config.mutation.maxMutants == 30)
    #expect(config.budgets == Budgets(t0: .seconds(5), t1: .seconds(60), stopHook: .seconds(90)))
    #expect(config.flows.isEmpty && config.modules.isEmpty)
    #expect(config.judge == .disabled)
  }

  @Test("unknown keys at every level are errors — catches a typo like max_flow silently ignored")
  func unknownKeys() {
    let found = issues(
      Self.minimal + """
        max_flow = 3
        [pyramid]
        max_flow = 3
        [[modules]]
        name = "X"
        knd = "engine"
        """)
    #expect(
      found == [
        .unknownKey(path: "simulator.max_flow"),
        .unknownKey(path: "pyramid.max_flow"),
        .unknownKey(path: "modules[0].knd"),
      ])
  }

  @Test("unknown module kind is an error — catches kind = \"engin\" falling back to feature")
  func unknownKind() {
    let found = issues(
      Self.minimal + """
        [[modules]]
        name = "Physics"
        kind = "engin"
        reason = "fixed timestep"
        """)
    #expect(found == [.unknownModuleKind(path: "modules[0].kind", value: "engin")])
  }

  @Test("non-default kind without reason is an error — catches undeclared escapes from TCA")
  func nonDefaultKindWithoutReason() {
    let found = issues(
      Self.minimal + """
        [[modules]]
        name = "Renderer"
        kind = "render"
        [[modules]]
        name = "Shared"
        kind = "library"
        reason = "   "
        """)
    #expect(
      found == [
        .missingReason(
          path: "modules[0].reason", module: "Renderer", rule: .nonDefaultKind(.render)),
        .missingReason(
          path: "modules[1].reason", module: "Shared", rule: .nonDefaultKind(.library)),
      ])
  }

  @Test("host_testable = false without reason is an error — catches logic silently moved off T1")
  func notHostTestableWithoutReason() {
    let found = issues(
      Self.minimal + """
        [[modules]]
        name = "HealthCore"
        host_testable = false
        """)
    #expect(
      found == [
        .missingReason(path: "modules[0].reason", module: "HealthCore", rule: .notHostTestable)
      ])
  }

  @Test("more flows than max_flows is an error — catches the T3 closed list growing unchecked")
  func tooManyFlows() {
    let found = issues(
      Self.minimal + """
        [pyramid]
        max_flows = 1
        [[flows]]
        name = "checkout"
        reason = "revenue"
        [[flows]]
        name = "login"
        reason = "auth"
        """)
    #expect(found == [.tooManyFlows(count: 2, max: 1)])
  }

  @Test("every problem is reported at once — catches fix-one-rerun-find-the-next loops")
  func reportsAllIssues() {
    let found = issues(
      """
      schema = 2
      app_scheme = 7
      packages = ["Packages/*"]
      bogus = true

      [simulator]
      device = "iPhone 17"
      os = "26.2"
      max_concurrent = 0

      [pyramid]
      diff_coverage_min = 1.5

      [[modules]]
      name = "A"
      kind = "nope"

      [[modules]]
      name = "A"
      host_testable = "no"

      [judge]
      backend = "claude"
      advisory_threshold = 0.9
      block_threshold = 0.5
      """)
    #expect(
      found == [
        .unknownKey(path: "bogus"),
        .unsupportedSchema(found: 2),
        .missingKey(path: "xcode"),
        .wrongType(path: "app_scheme", expected: "string", found: "integer"),
        .unknownModuleKind(path: "modules[0].kind", value: "nope"),
        .wrongType(path: "modules[1].host_testable", expected: "boolean", found: "string"),
        .outOfRange(path: "simulator.max_concurrent", value: "0", allowed: ">= 1"),
        .outOfRange(path: "pyramid.diff_coverage_min", value: "1.5", allowed: "0...1"),
        .duplicateName(path: "modules[1].name", name: "A"),
        .judgeThresholdsInverted(advisory: 0.9, block: 0.5),
      ])
  }

  @Test("enabled judge without thresholds is an error — catches a judge running with no policy")
  func judgeNeedsThresholds() {
    let found = issues(
      Self.minimal + """
        [judge]
        backend = "claude"
        """)
    #expect(
      found == [
        .missingKey(path: "judge.advisory_threshold"), .missingKey(path: "judge.block_threshold"),
      ])
  }

  @Test("unknown judge backend is an error — catches test source sent to an unintended service")
  func unknownJudgeBackend() {
    let found = issues(
      Self.minimal + """
        [judge]
        backend = "gpt"
        advisory_threshold = 0.5
        block_threshold = 0.9
        """)
    #expect(found == [.unknownJudgeBackend(path: "judge.backend", value: "gpt")])
  }

  @Test("TOML syntax error reports line and column — catches a parse failure reported as valid")
  func syntaxError() {
    #expect {
      _ = try decoder.decode("schema = 1\nxcode = \n")
    } throws: { error in
      guard case .syntax(let line, _, _) = error as? ConfigLoadError else { return false }
      return line == 2
    }
  }

  @Test("date-time values are rejected by type, not crashed on — catches unsupported TOML types")
  func dateTimeValue() {
    let found = issues(
      Self.minimal.replacingOccurrences(of: "\"26.2\"\napp", with: "2026-01-01\napp"))
    #expect(found == [.wrongType(path: "xcode", expected: "string", found: "local date")])
  }
}
