// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "swiftgate",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "swiftgate", targets: ["SwiftGateCLI"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/mattt/swift-toml", from: "2.0.0"),
    .package(url: "https://github.com/swiftlang/swift-syntax", "602.0.0"..<"603.0.0"),
  ],
  targets: [
    .target(name: "SwiftGateDomain"),
    .target(
      name: "SwiftGateRules",
      dependencies: [
        "SwiftGateDomain",
        .product(name: "SwiftSyntax", package: "swift-syntax"),
        .product(name: "SwiftParser", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "SwiftGateAdapters",
      dependencies: ["SwiftGateDomain", .product(name: "TOML", package: "swift-toml")]
    ),
    .executableTarget(
      name: "SwiftGateCLI",
      dependencies: [
        "SwiftGateDomain",
        "SwiftGateAdapters",
        "SwiftGateRules",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .target(name: "SwiftGateTestSupport", dependencies: ["SwiftGateDomain", "SwiftGateAdapters"]),
    .testTarget(
      name: "SwiftGateDomainTests", dependencies: ["SwiftGateDomain", "SwiftGateTestSupport"]),
    .testTarget(
      name: "SwiftGateAdaptersTests",
      dependencies: ["SwiftGateDomain", "SwiftGateAdapters", "SwiftGateTestSupport"]
    ),
    .testTarget(
      name: "SwiftGateRulesTests",
      dependencies: ["SwiftGateDomain", "SwiftGateRules"]
    ),
    .testTarget(name: "SwiftGateTestSupportTests", dependencies: ["SwiftGateTestSupport"]),
    .testTarget(
      name: "SwiftGateCLITests",
      dependencies: ["SwiftGateCLI", "SwiftGateAdapters", "SwiftGateTestSupport"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
