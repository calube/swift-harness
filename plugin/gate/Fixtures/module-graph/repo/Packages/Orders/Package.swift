// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Orders",
  dependencies: [.package(path: "../Logging")],
  targets: [
    .target(name: "OrderQueueClient"),
    .target(
      name: "OrderQueueClientLive",
      dependencies: ["OrderQueueClient", .product(name: "LogClient", package: "Logging")]),
    .target(name: "OrderQueueCore", dependencies: ["OrderQueueClient"]),
    .target(name: "OrderQueueUI", dependencies: ["OrderQueueCore"]),
    .testTarget(name: "OrderQueueCoreTests", dependencies: ["OrderQueueCore"]),
  ]
)
