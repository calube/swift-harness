// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Greeter",
  platforms: [.macOS(.v15)],
  targets: [
    .target(name: "Greeter"),
    .testTarget(name: "GreeterTests", dependencies: ["Greeter"]),
  ],
  swiftLanguageModes: [.v6]
)
