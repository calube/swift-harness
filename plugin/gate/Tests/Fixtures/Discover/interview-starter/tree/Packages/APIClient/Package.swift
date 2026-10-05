// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "APIClient",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "APIClient", targets: ["APIClient"]),
    .library(name: "APIClientLive", targets: ["APIClientLive"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1")
  ],
  targets: [
    .target(
      name: "APIClient",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .target(
      name: "APIClientLive",
      dependencies: [
        "APIClient",
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "APIClientTests",
      dependencies: [
        "APIClient",
        .product(name: "Dependencies", package: "swift-dependencies"),
      ]
    ),
    .testTarget(
      name: "APIClientLiveTests",
      dependencies: ["APIClient", "APIClientLive"],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
