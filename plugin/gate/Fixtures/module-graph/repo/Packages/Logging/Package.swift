// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Logging",
  products: [.library(name: "LogClient", targets: ["LogClient"])],
  targets: [.target(name: "LogClient")]
)
