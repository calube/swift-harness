import SwiftGateDomain
import Testing

@Suite("warm-up reuse at a warmed ancestor")
struct WarmReuseTests {
  private struct Unreadable: Error {}

  private static func area(_ name: String, root: String) -> BrownfieldArea {
    BrownfieldArea(
      name: name, root: root, language: .go, kind: .go, test: "test", testFiles: nil, lint: nil,
      build: "build", e2e: nil, testGlobs: [], packs: [], xcode: nil)
  }

  private static let api = area("api", root: "api")
  private static let web = area("web", root: "web")

  private static func owner(_ path: String) -> String? {
    path.hasPrefix("api/") ? "api" : path.hasPrefix("web/") ? "web" : nil
  }

  /// The merge base `m2`, a merge `m1` before it, the contract `c0`, then the warmed base `b0`.
  private static let history = [
    CommitTree(commit: "m2", tree: "t-m2"), CommitTree(commit: "m1", tree: "t-m1"),
    CommitTree(commit: "c0", tree: "t-c0"), CommitTree(commit: "b0", tree: "t-b0"),
  ]

  @Test(
    "each area takes its time from the nearest warmed ancestor whose files it owns didn't change, and the merge base's own warm-up wins — catches a lookup only at the merge base's exact tree"
  )
  func nearestUnchangedAncestorIsCurrent() async {
    let warm: [String: [String: Int]] = [
      "t-m2": ["web": 4_000], "t-c0": ["api": 2_000], "t-b0": ["api": 9_000, "web": 9_000],
    ]

    let resolution = await WarmReuse.resolve(
      [Self.api, Self.web], mergeBase: "m2", history: Self.history, owner: Self.owner,
      warmTest: { area, tree in warm[tree]?[area.name] },
      changed: { from, _ in from == "c0" ? ["web/src/app.ts"] : [] })

    #expect(
      resolution.times == [
        "api": .current(milliseconds: 2_000, at: CommitTree(commit: "c0", tree: "t-c0")),
        "web": .current(milliseconds: 4_000, at: CommitTree(commit: "m2", tree: "t-m2")),
      ])
    #expect(resolution.notes.isEmpty)
  }

  @Test(
    "an area whose own files, or files no area owns, changed since the warmed ancestor reads stale and names them — catches a warm time reused for code the warm-up never built"
  )
  func changedAreaIsStale() async {
    let warm: [String: [String: Int]] = ["t-b0": ["api": 2_000, "web": 3_000]]

    let resolution = await WarmReuse.resolve(
      [Self.api, Self.web], mergeBase: "m2", history: Self.history, owner: Self.owner,
      warmTest: { area, tree in warm[tree]?[area.name] },
      changed: { _, _ in ["api/store/share.go", "go.mod"] })

    let base = CommitTree(commit: "b0", tree: "t-b0")
    #expect(
      resolution.times == [
        "api": .stale(milliseconds: 2_000, at: base, changed: ["api/store/share.go", "go.mod"]),
        "web": .stale(milliseconds: 3_000, at: base, changed: ["go.mod"]),
      ])
  }

  @Test(
    "an area no warm-up measured is unmeasured, and a changed-files read that fails leaves the area unmeasured with a note — catches a warm time reused when git couldn't say what changed"
  )
  func unreadableChangeIsUnmeasured() async {
    let resolution = await WarmReuse.resolve(
      [Self.api, Self.web], mergeBase: "m2", history: Self.history, owner: Self.owner,
      warmTest: { area, tree in tree == "t-b0" && area.name == "api" ? 2_000 : nil },
      changed: { _, _ in throw Unreadable() })

    #expect(resolution.times == ["api": .unmeasured, "web": .unmeasured])
    #expect(resolution.notes.count == 1)
    #expect(resolution.notes.first?.contains("b0") == true, "\(resolution.notes)")
  }
}
