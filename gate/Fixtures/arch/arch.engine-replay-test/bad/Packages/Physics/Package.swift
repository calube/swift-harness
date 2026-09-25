// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Physics",
  targets: [
    .target(name: "PhysicsCore"),
    .testTarget(name: "PhysicsCoreTests", dependencies: ["PhysicsCore"]),
  ]
)
