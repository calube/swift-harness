import SwiftGateDomain
import Testing

@Suite("task return manifests against the plan surface")
struct TaskReturnSurfaceManifestTests {
  static let surface = "5d1f0c2a9b8e7d6c5b4a39281706f5e4d3c2b1a0"

  static func taskReturn() -> TaskReturn {
    TaskReturn(
      task: "t", outcome: .readyToMerge, commits: ["abc1"],
      gate: .init(tier: .push, verdict: .green, runID: "r1"),
      review: .init(mode: .gate, findings: []), testsAdded: [], notes: "", designConflict: nil)
  }

  static func evidence(_ manifests: [SliceManifest]?) -> TaskReturnEvidence {
    TaskReturnEvidence(
      branch: "p/t", branchExists: true, commits: ["abc1": .onBranch],
      gateRun: .init(
        tier: .push, verdict: .green, steps: ["impact", "coverage", "app-build"], dirty: false),
      taskGate: .push, taskStatus: nil, taskGateStepsRequired: true,
      planSurface: manifests.map { PlanSurfaceManifests(surface: surface, manifests: $0) })
  }

  static func declared(_ targets: Set<String>, _ products: Set<String>) -> ManifestReading {
    .declared(ManifestDeclarations(targets: targets, products: products))
  }

  static func findings(_ manifests: [SliceManifest]?) -> [TaskReturnFinding] {
    TaskReturnCheck.findings(taskReturn(), evidence: evidence(manifests))
  }

  @Test(
    "each manifest declaring what the plan surface lacks is its own finding, in path order, naming its targets, products and the design conflict fix — catches undeclared targets merged into one finding or dropped"
  )
  func eachUndeclaredManifestIsNamed() {
    let found = Self.findings([
      SliceManifest(
        path: "Packages/Z/Package.swift", atSurface: Self.declared(["Z"], ["Z"]),
        atHead: Self.declared(["Z", "ZLive"], ["Z"])),
      SliceManifest(
        path: "Packages/A/Package.swift", atSurface: Self.declared(["A"], []),
        atHead: Self.declared(["A"], ["A"])),
    ])

    #expect(found.map(\.rule) == [.targetOutsideSurface, .targetOutsideSurface])
    #expect(
      found.map(\.message).first?.hasPrefix(
        "Packages/A/Package.swift adds product A, which the plan surface \(Self.surface) doesn't "
          + "declare") == true, "\(found)")
    #expect(
      found.map(\.message).last?.hasPrefix(
        "Packages/Z/Package.swift adds target ZLive, which the plan surface \(Self.surface) "
          + "doesn't declare") == true, "\(found)")
    #expect(found.allSatisfy { $0.message.contains("return a design conflict") }, "\(found)")
  }

  @Test(
    "a manifest the surface can't be read at names the surface commit, and one filling declared targets, deleted, or only reordered is quiet — catches an unreadable surface passed or a harmless edit flagged"
  )
  func unreadableSurfaceAndHarmlessEdits() {
    let found = Self.findings([
      SliceManifest(
        path: "Packages/A/Package.swift", atSurface: .unreadable("it has no `Package(…)` call"),
        atHead: Self.declared(["A"], [])),
      SliceManifest(
        path: "Packages/B/Package.swift", atSurface: Self.declared(["B", "C"], ["B"]),
        atHead: Self.declared(["C", "B"], ["B"])),
      SliceManifest(
        path: "Packages/D/Package.swift", atSurface: Self.declared(["D"], []), atHead: nil),
    ])

    #expect(found.map(\.rule) == [.targetOutsideSurface])
    #expect(
      found.first?.message.hasPrefix(
        "Packages/A/Package.swift can't be read at the plan surface \(Self.surface) (it has no "
          + "`Package(…)` call)") == true, "\(found)")
  }

  @Test(
    "the same undeclared target is a finding only when the plan has a surface commit, and a branch that changed no manifest is quiet — catches a plan built without a plan surface refused"
  )
  func noSurfaceOrNoManifestIsQuiet() {
    let added = SliceManifest(
      path: "Packages/A/Package.swift", atSurface: Self.declared(["A"], []),
      atHead: Self.declared(["A", "ALive"], []))

    #expect(Self.findings([added]).map(\.rule) == [.targetOutsideSurface])
    #expect(Self.findings(nil) == [])
    #expect(Self.findings([]) == [])
  }
}
