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
    .package(url: "https://github.com/DataDog/dd-sdk-ios", exact: "2.22.0"),
    .package(path: "../HTTPClient"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", exact: "1.4.1"),
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
        .product(name: "DatadogRUM", package: "dd-sdk-ios"),
        .product(name: "HTTPClient", package: "HTTPClient"),
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
      dependencies: [
        "APIClientLive",
        .product(name: "HTTPClient", package: "HTTPClient"),
        .product(name: "Clocks", package: "swift-clocks"),
        .product(name: "ConcurrencyExtras", package: "swift-concurrency-extras"),
      ],
      resources: [.copy("Fixtures")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
