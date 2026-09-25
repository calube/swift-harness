// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "swiftgate",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "swiftgate", targets: ["SwiftGateCLI"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2")
  ],
  targets: [
    .target(name: "SwiftGateDomain"),
    .target(name: "SwiftGateAdapters", dependencies: ["SwiftGateDomain"]),
    .executableTarget(
      name: "SwiftGateCLI",
      dependencies: [
        "SwiftGateDomain",
        "SwiftGateAdapters",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(name: "SwiftGateDomainTests", dependencies: ["SwiftGateDomain"]),
    .testTarget(name: "SwiftGateCLITests", dependencies: ["SwiftGateCLI"]),
  ],
  swiftLanguageModes: [.v6]
)
