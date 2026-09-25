// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Feed",
  dependencies: [
    .package(url: "https://github.com/DataDog/dd-sdk-ios", from: "3.0.0"),
  ],
  targets: [
    .target(name: "FeedClient"),
    .target(name: "FeedClientLive", dependencies: ["FeedClient", .product(name: "DatadogRUM", package: "dd-sdk-ios")]),
    .target(name: "FeedCore", dependencies: ["FeedClient"]),
    .target(name: "FeedUI", dependencies: ["FeedCore"]),
    .testTarget(name: "FeedCoreTests", dependencies: ["FeedCore"]),
  ]
)
