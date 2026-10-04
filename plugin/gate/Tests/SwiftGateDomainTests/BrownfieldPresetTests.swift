import SwiftGateDomain
import Testing

@Suite("brownfield preset and tiers")
struct BrownfieldPresetTests {
  private func brownfieldIssues(preset: [String: ConfigValue]) -> [ConfigIssue] {
    do {
      _ = try BrownfieldConfigSchema.config(from: BrownfieldConfigSample.document(preset: preset))
      return []
    } catch {
      return error.issues
    }
  }

  /// An owned `.swiftgate.toml` with 1 preset whose `task_gate` is `taskGate`.
  private func ownedIssues(taskGate: String) -> [ConfigIssue] {
    var preset = BrownfieldConfigSample.presetTable
    preset["task_gate"] = .string(taskGate)
    preset["merge_gate"] = .string("push")
    preset["worker_model"] = .string("sonnet")
    preset["review"] = .string("full")
    preset["task_proof"] = .string("per-task")
    preset["sim_qa"] = .string("off")
    let root: ConfigValue = .table([
      "schema": .integer(1), "xcode": .string("26.2"), "app_scheme": .string("App"),
      "packages": .array([.string("Packages/*")]),
      "simulator": .table(["device": .string("iPhone 17"), "os": .string("26.2")]),
      "build": .table(["presets": .table(["fast": .table(preset)])]),
    ])
    do {
      _ = try ConfigSchema.config(from: root)
      return []
    } catch {
      return error.issues
    }
  }

  @Test(
    "the brownfield preset reads classified review, slice and merge gates, prove, stall_min and a pinned model — catches a preset value read as its default"
  )
  func brownfieldPresetDecodes() throws {
    let config = try BrownfieldConfigSchema.config(from: BrownfieldConfigSample.document())
    #expect(config.buildPresets["brownfield"] == BrownfieldConfigSample.preset)
    #expect(config.buildPresets["brownfield"]?.workerModel == .claudeSonnet55)
  }

  @Test("worker_model = \"sonnet-5\" fails naming the pinned ids — catches an open model string")
  func unknownModelFails() {
    let found = brownfieldIssues(preset: ["worker_model": .string("sonnet-5")])
    #expect(
      found == [
        .unknownEnumValue(
          path: "build.presets.brownfield.worker_model", value: "sonnet-5",
          allowed: ["tagged", "claude-sonnet-5-5", "claude-opus-5-5"])
      ])
  }

  @Test("a moving alias fails in a brownfield clone, naming the profile — catches an unpinned run")
  func aliasFailsInBrownfield() {
    let found = brownfieldIssues(preset: ["worker_model": .string("sonnet")])
    #expect(
      found == [
        .notInProfile(
          path: "build.presets.brownfield.worker_model", value: "sonnet", profile: .brownfield,
          allowed: ["tagged", "claude-sonnet-5-5", "claude-opus-5-5"])
      ])
  }

  @Test(
    "task_gate = \"slice\" in an owned config fails naming the owned profile — catches tiers leaking across profiles"
  )
  func brownfieldTierFailsInOwned() {
    let found = ownedIssues(taskGate: "slice")
    #expect(
      found == [
        .notInProfile(
          path: "build.presets.fast.task_gate", value: "slice", profile: .owned,
          allowed: ["ledger", "fast", "push", "ready"])
      ])
    #expect(found.first?.description.contains("owned profile") == true)
    #expect(ownedIssues(taskGate: "push") == [])
  }

  @Test(
    "task_gate = \"push\" in a brownfield config fails naming the brownfield profile — catches tiers leaking across profiles"
  )
  func ownedTierFailsInBrownfield() {
    let found = brownfieldIssues(preset: [
      "task_gate": .string("push"), "merge_gate": .string("ready"),
    ])
    #expect(
      found == [
        .notInProfile(
          path: "build.presets.brownfield.task_gate", value: "push", profile: .brownfield,
          allowed: ["ledger", "slice", "merge", "final"]),
        .notInProfile(
          path: "build.presets.brownfield.merge_gate", value: "ready", profile: .brownfield,
          allowed: ["slice", "merge", "final"]),
      ])
    #expect(found.first?.description.contains("brownfield profile") == true)
  }

  @Test("stall_min = 0 fails — catches a stall watch that fires at once")
  func zeroStallFails() {
    #expect(
      brownfieldIssues(preset: ["stall_min": .integer(0)]) == [
        .outOfRange(path: "build.presets.brownfield.stall_min", value: "0", allowed: ">= 1")
      ])
  }

  @Test(
    "a tier covers only lower tiers of its own profile — catches a brownfield gate accepted for an owned one"
  )
  func coversStaysInProfile() {
    #expect(TaskReturnCheck.covers(.ready, .push))
    #expect(TaskReturnCheck.covers(.merge, .slice))
    #expect(TaskReturnCheck.covers(.final, .merge))
    #expect(!TaskReturnCheck.covers(.slice, .push))
    #expect(!TaskReturnCheck.covers(.final, .fast))
    #expect(!TaskReturnCheck.covers(.ready, .slice))
    #expect(!TaskReturnCheck.covers(.slice, .merge))
  }
}
