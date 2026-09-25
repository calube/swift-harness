// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "GameEngine",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "GameEngine", targets: ["GameEngine"])
  ],
  targets: [
    .target(name: "GameEngine"),
    .testTarget(name: "GameEngineTests", dependencies: ["GameEngine"]),
  ],
  swiftLanguageModes: [.v6]
)
