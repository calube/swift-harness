// swift-tools-version: 6.2
import PackageDescription

// The mutate self-test: `change/` edits ScoreCore; `weak/` and `strong/` are two test suites for
// the change. The weak one leaves mutants alive (RED), the strong one kills them all (GREEN).
let package = Package(
  name: "Scorer",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "ScoreCore"),
    .testTarget(name: "ScoreCoreTests", dependencies: ["ScoreCore"]),
  ],
  swiftLanguageModes: [.v6]
)
