// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Feed",
  targets: [
    .target(name: "FeedClient"),
    .target(name: "FeedClientLive", dependencies: ["FeedClient"]),
    .target(name: "FeedCore", dependencies: ["FeedClient", "FeedClientLive"]),
    .target(name: "FeedUI", dependencies: ["FeedCore"]),
    .testTarget(name: "FeedCoreTests", dependencies: ["FeedCore"]),
  ]
)
