// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "HostTarget",
  platforms: [.macOS(.v15)],
  products: [.library(name: "HostTarget", targets: ["HostTarget"])],
  targets: [.target(name: "HostTarget")],
  swiftLanguageModes: [.v6]
)
