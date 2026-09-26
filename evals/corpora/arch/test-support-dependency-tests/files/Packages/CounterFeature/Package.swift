// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "CounterFeature",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "CounterCore", targets: ["CounterCore"]),
    .library(name: "CounterUI", targets: ["CounterUI"]),
  ],
  dependencies: [
    .package(path: "../APIClient"),
    .package(path: "../LogClient"),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      exact: "1.26.2",
      traits: ["ComposableArchitecture2Deprecations"]
    ),
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6"),
  ],
  targets: [
    .target(name: "CounterTestSupport"),
    .target(
      name: "CounterCore",
      dependencies: [
        .product(name: "APIClient", package: "APIClient"),
        .product(name: "LogClient", package: "LogClient"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // iOS-only: sources are compiled out on macOS so `swift test` on the host stays Core-only.
    .target(
      name: "CounterUI",
      dependencies: [
        "CounterCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "CounterCoreTests",
      dependencies: [
        "CounterTestSupport",
        "CounterCore",
        .product(name: "APIClient", package: "APIClient"),
        .product(name: "LogClient", package: "LogClient"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // Runs on the iOS simulator only (`xcodebuild test`); compiled out under host `swift test`.
    .testTarget(
      name: "CounterUISnapshotTests",
      dependencies: [
        "CounterUI",
        "CounterCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
