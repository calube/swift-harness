import Testing

@testable import SwiftGateDomain

@Suite("review-input: SwiftUI reach")
struct SwiftUIReachTests {
  @Test(
    "a file maps to its SwiftPM target directory — catches a UI module missed because the changed file itself has no SwiftUI import"
  )
  func moduleDirectory() {
    #expect(
      SwiftUIReach.moduleDirectory(of: "Packages/Counter/Sources/CounterUI/Row.swift")
        == "Packages/Counter/Sources/CounterUI/")
    #expect(
      SwiftUIReach.moduleDirectory(of: "Pkg/Sources/Core/Nested/Deep.swift") == "Pkg/Sources/Core/")
    #expect(SwiftUIReach.moduleDirectory(of: "App/ContentView.swift") == nil)
    #expect(SwiftUIReach.moduleDirectory(of: "Pkg/Sources/Loose.swift") == nil)
  }

  @Test(
    "only units that import SwiftUI are reported, deduplicated — catches the SwiftUI reviewer running on a Core-only diff"
  )
  func touchedUnits() {
    let units = SwiftUIReach.touchedUnits(
      changedSwiftFiles: [
        "P/Sources/CounterUI/A.swift", "P/Sources/CounterUI/B.swift",
        "P/Sources/CounterCore/C.swift",
        "App/RootView.swift",
      ],
      importsSwiftUI: { $0 == "P/Sources/CounterUI/" || $0 == "App/RootView.swift" })
    #expect(units == ["App/RootView.swift", "P/Sources/CounterUI/"])
  }

  @Test(
    "import detection accepts modifiers and attributes and rejects look-alikes — catches SwiftUIIntrospect or a comment triggering the reviewer",
    arguments: [
      ("import SwiftUI", true), ("public import SwiftUI", true),
      ("@preconcurrency import SwiftUI", true), ("  import SwiftUI // views", true),
      ("import SwiftUIIntrospect", false), ("// import SwiftUI", false),
      ("import ComposableArchitecture", false),
    ])
  func importDetection(line: String, expected: Bool) {
    #expect(SwiftUIReach.importsSwiftUI("import Foundation\n\(line)\n") == expected)
  }

  @Test(
    "the manifest lists swiftui as a focus only when SwiftUI is touched — catches a not-applicable SwiftUI focus blocking merge"
  )
  func manifestFocuses() {
    let artifacts = ReviewInputManifest.Artifacts(
      check: "check.json", arch: "arch.json", testlint: "testlint.json", comments: "comments.json",
      diff: "diff.patch", mutate: nil)
    let without = ReviewInputManifest(
      runID: "r", base: "origin/main", mergeBase: "abc", gateVerdict: .green, changedFiles: [],
      swiftUIUnits: [], artifacts: artifacts, notes: [])
    let with = ReviewInputManifest(
      runID: "r", base: "origin/main", mergeBase: "abc", gateVerdict: .green, changedFiles: [],
      swiftUIUnits: ["P/Sources/UI/"], artifacts: artifacts, notes: [])
    #expect(!without.focuses.contains(.swiftui))
    #expect(with.focuses == ReviewFocus.allCases)
  }
}
