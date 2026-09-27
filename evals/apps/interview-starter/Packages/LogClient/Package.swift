// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "LogClient",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "LogClient", targets: ["LogClient"]),
    .library(name: "LogClientLive", targets: ["LogClientLive"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", exact: "1.4.1"),
  ],
  targets: [
    .target(
      name: "LogClient",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .target(name: "LogClientLive", dependencies: ["LogClient"]),
    .testTarget(
      name: "LogClientTests",
      dependencies: [
        "LogClient", .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
      ]
    ),
    .testTarget(name: "LogClientLiveTests", dependencies: ["LogClientLive"]),
  ],
  swiftLanguageModes: [.v6]
)
