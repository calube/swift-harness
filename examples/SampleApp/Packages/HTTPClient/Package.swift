// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "HTTPClient",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "HTTPClient", targets: ["HTTPClient"]),
    .library(name: "HTTPClientLive", targets: ["HTTPClientLive"]),
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1")
  ],
  targets: [
    .target(
      name: "HTTPClient",
      dependencies: [
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "DependenciesMacros", package: "swift-dependencies"),
      ]
    ),
    .target(name: "HTTPClientLive", dependencies: ["HTTPClient"]),
    .testTarget(name: "HTTPClientTests", dependencies: ["HTTPClient"]),
    .testTarget(name: "HTTPClientLiveTests", dependencies: ["HTTPClientLive"]),
  ],
  swiftLanguageModes: [.v6]
)
