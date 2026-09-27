// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AppFeature",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .library(name: "AppUI", targets: ["AppUI"]),
  ],
  dependencies: [
    .package(path: "../APIClient"),
    .package(path: "../LogClient"),
    .package(
      url: "https://github.com/pointfreeco/swift-composable-architecture",
      exact: "1.26.2",
      traits: ["ComposableArchitecture2Deprecations"]
    ),
  ],
  targets: [
    .target(
      name: "AppCore",
      dependencies: [
        .product(name: "APIClient", package: "APIClient"),
        .product(name: "LogClient", package: "LogClient"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    // iOS-only: sources are compiled out on macOS so `swift test` on the host stays Core-only.
    .target(
      name: "AppUI",
      dependencies: [
        "AppCore",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: [
        "AppCore",
        .product(name: "APIClient", package: "APIClient"),
        .product(name: "LogClient", package: "LogClient"),
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
