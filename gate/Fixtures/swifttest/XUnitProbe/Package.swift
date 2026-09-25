// swift-tools-version: 6.2
import PackageDescription

// Captures real `swift test --xunit-output` reports for the T1 evidence rules. Each scenario is
// selected with `--filter`; see gate/Tests/Fixtures/README.md for the capture commands.
let package = Package(
  name: "XUnitProbe",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "Probe"),
    .testTarget(name: "ProbeTests", dependencies: ["Probe"]),
    .testTarget(name: "EmptyTests", dependencies: ["Probe"]),
  ],
  swiftLanguageModes: [.v6]
)
