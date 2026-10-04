// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "AccessibilityIDs",
  platforms: [.iOS(.v18), .macOS(.v15)],
  products: [
    .library(name: "AccessibilityIDs", targets: ["AccessibilityIDs"])
  ],
  targets: [
    .target(name: "AccessibilityIDs")
  ],
  swiftLanguageModes: [.v6]
)
